package controller

import (
	"context"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	v1alpha1 "github.com/matheus/retro-k8s/operator/api/v1alpha1"
)

func testScheme(t *testing.T) *runtime.Scheme {
	t.Helper()
	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(v1alpha1.AddToScheme(scheme))
	return scheme
}

func testReconciler(c client.Client, scheme *runtime.Scheme) *RetroSessionReconciler {
	return &RetroSessionReconciler{
		Client:   c,
		Scheme:   scheme,
		Recorder: record.NewFakeRecorder(100),
		Config: SessionConfig{
			DefaultImage:     "retro-k8s-poc/retroarch-input:pilot",
			RelayImage:       "retro-k8s-poc/frontend:pilot",
			LocalMediaImage:  "bluenviron/mediamtx:1",
			ImagePullPolicy:  corev1.PullNever,
			ROMLibraryPath:   "/run/retro-k8s-input/roms",
			ROMMountPath:     "/roms",
			NodeInputRoot:    "/run/retro-k8s-input",
			TokenSecretName:  "retro-session-secret",
			MediaService:     "mediamtx",
			MediaRTMPPort:    1935,
			SessionUID:       1000,
			SessionGID:       1001,
			InputGID:         104,
			AgentPort:        8765,
			PadPrefix:        "Retro-K8s Pad",
			DefaultLogLevel:  "INFO",
			DefaultMinHoldMS: 40,
		},
	}
}

func newTestClient(t *testing.T, objects ...client.Object) client.Client {
	t.Helper()
	return fake.NewClientBuilder().
		WithScheme(testScheme(t)).
		WithStatusSubresource(&v1alpha1.RetroSession{}, &corev1.Pod{}).
		WithObjects(objects...).
		Build()
}

func newSession() *v1alpha1.RetroSession {
	return &v1alpha1.RetroSession{
		TypeMeta: metav1.TypeMeta{APIVersion: v1alpha1.GroupVersion.String(), Kind: "RetroSession"},
		ObjectMeta: metav1.ObjectMeta{
			Name:       "chrono-trigger",
			Namespace:  "retro-k8s",
			UID:        types.UID("session-uid"),
			Generation: 1,
		},
		Spec: v1alpha1.RetroSessionSpec{
			Console:       v1alpha1.ConsoleSNES,
			ROM:           "Chrono Trigger (USA).sfc",
			SaveClaimName: "chrono-trigger-saves",
		},
	}
}

func newBoundPVC() *corev1.PersistentVolumeClaim {
	return &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{Name: "chrono-trigger-saves", Namespace: "retro-k8s"},
		Status:     corev1.PersistentVolumeClaimStatus{Phase: corev1.ClaimBound},
	}
}

func reconcileSession(t *testing.T, r *RetroSessionReconciler, session *v1alpha1.RetroSession) ctrl.Result {
	t.Helper()
	result, err := r.Reconcile(context.Background(), ctrl.Request{
		NamespacedName: types.NamespacedName{Namespace: session.Namespace, Name: session.Name},
	})
	if err != nil {
		t.Fatalf("Reconcile returned error: %v", err)
	}
	return result
}

func TestReconcileCreatesDeploymentAndService(t *testing.T) {
	session := newSession()
	c := newTestClient(t, session, newBoundPVC())
	r := testReconciler(c, testScheme(t))

	reconcileSession(t, r, session)

	var deployment appsv1.Deployment
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: session.Namespace, Name: session.Name}, &deployment); err != nil {
		t.Fatalf("Deployment was not created: %v", err)
	}
	if !metav1.IsControlledBy(&deployment, session) {
		t.Fatal("Deployment is not controlled by the RetroSession")
	}
	if deployment.Spec.Replicas == nil || *deployment.Spec.Replicas != 1 {
		t.Fatalf("expected 1 replica, got %v", deployment.Spec.Replicas)
	}
	if deployment.Spec.Strategy.Type != appsv1.RecreateDeploymentStrategyType {
		t.Fatalf("expected Recreate strategy, got %s", deployment.Spec.Strategy.Type)
	}
	if len(deployment.Spec.Template.Spec.Containers) != 3 {
		t.Fatalf("expected session, audio relay, and local media containers; got %d", len(deployment.Spec.Template.Spec.Containers))
	}
	container := deployment.Spec.Template.Spec.Containers[0]
	local := deployment.Spec.Template.Spec.Containers[2]
	if local.Name != "local-media" || local.Image != "bluenviron/mediamtx:1" {
		t.Fatalf("unexpected local media container: %s %s", local.Name, local.Image)
	}
	relay := deployment.Spec.Template.Spec.Containers[1]
	if !strings.Contains(relay.Args[0], "rtmp://127.0.0.1:1935/raw/chrono-trigger") || !strings.Contains(relay.Args[0], "rtsp://mediamtx:8554/chrono-trigger") {
		t.Fatalf("relay does not connect local ingest to shared playback: %q", relay.Args)
	}
	if deployment.Spec.Template.Spec.Containers[1].Name != "audio-relay" {
		t.Fatal("session must include its own audio relay")
	}
	if deployment.Spec.Template.Spec.Containers[1].Image != "retro-k8s-poc/frontend:pilot" {
		t.Fatal("audio relay must use the configured image")
	}
	if container.Image != "retro-k8s-poc/retroarch-input:pilot" {
		t.Fatalf("unexpected image %q", container.Image)
	}
	if container.SecurityContext == nil || container.SecurityContext.Privileged == nil || !*container.SecurityContext.Privileged {
		t.Fatal("session container must be privileged for the pilot's uinput access")
	}
	env := envMap(container.Env)
	for key, want := range map[string]string{
		"STREAM_URL":  "rtmp://127.0.0.1:1935/raw/chrono-trigger",
		"RTMP_HOST":   "127.0.0.1",
		"RTMP_PORT":   "1935",
		"CORE":        "snes9x",
		"ROM_PATH":    "/roms/Chrono Trigger (USA).sfc",
		"SESSION_ID":  "chrono-trigger",
		"DEVICE_NAME": "Retro-K8s Pad chrono-trigger",
		"SAVE_PATH":   "/saves",
		"AGENT_PORT":  "8765",
	} {
		if env[key] != want {
			t.Errorf("env %s = %q, want %q", key, env[key], want)
		}
	}
	if env["INPUT_TOKEN_SECRET"] != "" {
		t.Error("token must come from a Secret, not a literal env value")
	}
	if token := envByName(container.Env, "INPUT_TOKEN_SECRET"); token == nil || token.ValueFrom == nil || token.ValueFrom.SecretKeyRef == nil {
		t.Fatal("INPUT_TOKEN_SECRET must use a Secret reference")
	}
	if got := deployment.Spec.Template.Spec.Volumes[0].PersistentVolumeClaim.ClaimName; got != "chrono-trigger-saves" {
		t.Fatalf("save claim = %q", got)
	}
	if got := deployment.Spec.Template.Spec.Volumes[1].HostPath.Path; got != "/run/retro-k8s-input/roms" {
		t.Fatalf("ROM library hostPath = %q", got)
	}

	var service corev1.Service
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: session.Namespace, Name: "chrono-trigger-input"}, &service); err != nil {
		t.Fatalf("input Service was not created: %v", err)
	}
	if service.Spec.Ports[0].Port != 8765 {
		t.Fatalf("input Service port = %d", service.Spec.Ports[0].Port)
	}
	if service.Spec.Selector[sessionLabel] != session.Name {
		t.Fatalf("input Service selector = %v", service.Spec.Selector)
	}

	var updated v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Status.Phase != v1alpha1.PhasePending {
		t.Fatalf("phase = %s, want Pending", updated.Status.Phase)
	}
	if updated.Status.Endpoints == nil || updated.Status.Endpoints.InputService != "chrono-trigger-input" {
		t.Fatalf("unexpected endpoints: %+v", updated.Status.Endpoints)
	}
	if updated.Status.Endpoints.StreamPath != "chrono-trigger" {
		t.Fatalf("stream path = %q", updated.Status.Endpoints.StreamPath)
	}

	var pvc corev1.PersistentVolumeClaim
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: session.Namespace, Name: "chrono-trigger-saves"}, &pvc); err != nil {
		t.Fatal(err)
	}
	if len(pvc.OwnerReferences) != 0 {
		t.Fatal("save PVC must not be owned by the session")
	}
}

func TestSessionMediaUsesConfiguredLocalPort(t *testing.T) {
	r := testReconciler(nil, testScheme(t))
	r.Config.MediaRTMPPort = 1940
	session := newSession()
	pod := r.desiredDeployment(session).Spec.Template.Spec
	if got := envMap(pod.Containers[0].Env)["STREAM_URL"]; got != "rtmp://127.0.0.1:1940/raw/chrono-trigger" {
		t.Fatalf("session stream URL = %q", got)
	}
	if got := envMap(pod.Containers[2].Env)["MTX_RTMPADDRESS"]; got != "127.0.0.1:1940" {
		t.Fatalf("local RTMP address = %q", got)
	}
	if !strings.Contains(pod.Containers[1].Args[0], "rtmp://127.0.0.1:1940/raw/chrono-trigger") {
		t.Fatalf("relay input = %q", pod.Containers[1].Args)
	}
	if got := r.endpoints(session).RTMPURL; got != "rtmp://127.0.0.1:1940/raw/chrono-trigger" {
		t.Fatalf("status RTMP URL = %q", got)
	}
}

func TestReconcileDoesNotRewriteUnchangedStatus(t *testing.T) {
	session := newSession()
	c := newTestClient(t, session, newBoundPVC())
	r := testReconciler(c, testScheme(t))
	reconcileSession(t, r, session)

	var first v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &first); err != nil {
		t.Fatal(err)
	}
	reconcileSession(t, r, session)

	var second v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &second); err != nil {
		t.Fatal(err)
	}
	if first.ResourceVersion != second.ResourceVersion {
		t.Fatalf("steady-state reconcile rewrote status (resourceVersion %s -> %s)", first.ResourceVersion, second.ResourceVersion)
	}
}

func TestReconcileMissingSaveClaimFailsWithoutDeployment(t *testing.T) {
	session := newSession()
	c := newTestClient(t, session)
	r := testReconciler(c, testScheme(t))

	result := reconcileSession(t, r, session)
	if result.RequeueAfter == 0 {
		t.Fatal("expected a requeue while waiting for the save claim")
	}

	var updated v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Status.Phase != v1alpha1.PhaseFailed || updated.Status.Reason != "SaveClaimNotFound" {
		t.Fatalf("unexpected status: %s/%s", updated.Status.Phase, updated.Status.Reason)
	}

	var deployment appsv1.Deployment
	err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &deployment)
	if err == nil {
		t.Fatal("Deployment must not be created before the save claim exists")
	}
}

func TestReconcilePendingSaveClaimCreatesDeploymentButStaysPending(t *testing.T) {
	session := newSession()
	pvc := newBoundPVC()
	pvc.Status.Phase = corev1.ClaimPending
	c := newTestClient(t, session, pvc)
	r := testReconciler(c, testScheme(t))

	result := reconcileSession(t, r, session)
	if result.RequeueAfter == 0 {
		t.Fatal("expected a requeue while the save claim is pending")
	}

	var deployment appsv1.Deployment
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &deployment); err != nil {
		t.Fatalf("Deployment should exist so WaitForFirstConsumer claims can bind: %v", err)
	}
	var updated v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Status.Phase != v1alpha1.PhasePending || updated.Status.Reason != "SaveClaimNotBound" {
		t.Fatalf("unexpected status: %s/%s", updated.Status.Phase, updated.Status.Reason)
	}
}

func TestReconcileRepairsDeletedDeployment(t *testing.T) {
	session := newSession()
	c := newTestClient(t, session, newBoundPVC())
	r := testReconciler(c, testScheme(t))
	reconcileSession(t, r, session)

	var deployment appsv1.Deployment
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &deployment); err != nil {
		t.Fatal(err)
	}
	if err := c.Delete(context.Background(), &deployment); err != nil {
		t.Fatal(err)
	}

	reconcileSession(t, r, session)

	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &deployment); err != nil {
		t.Fatalf("Deployment was not repaired: %v", err)
	}
	var service corev1.Service
	if err := c.Get(context.Background(), client.ObjectKey{Namespace: session.Namespace, Name: "chrono-trigger-input"}, &service); err != nil {
		t.Fatalf("Service should still exist: %v", err)
	}
}

func TestReconcileRefusesForeignDeployment(t *testing.T) {
	session := newSession()
	foreign := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: session.Name, Namespace: session.Namespace},
	}
	c := newTestClient(t, session, newBoundPVC(), foreign)
	r := testReconciler(c, testScheme(t))

	reconcileSession(t, r, session)

	var updated v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Status.Phase != v1alpha1.PhaseFailed || updated.Status.Reason != "DeploymentReconcileFailed" {
		t.Fatalf("unexpected status: %s/%s", updated.Status.Phase, updated.Status.Reason)
	}
	var got appsv1.Deployment
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.OwnerReferences) != 0 {
		t.Fatal("operator must not adopt a foreign Deployment")
	}
}

func TestReconcileReportsReadyAndEndpoints(t *testing.T) {
	session := newSession()
	c := newTestClient(t, session, newBoundPVC())
	r := testReconciler(c, testScheme(t))
	reconcileSession(t, r, session)

	var deployment appsv1.Deployment
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &deployment); err != nil {
		t.Fatal(err)
	}
	deployment.Status.ObservedGeneration = deployment.Generation
	deployment.Status.AvailableReplicas = 1
	deployment.Status.ReadyReplicas = 1
	if err := c.Status().Update(context.Background(), &deployment); err != nil {
		t.Fatalf("update Deployment status: %v", err)
	}

	reconcileSession(t, r, session)

	var updated v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Status.Phase != v1alpha1.PhaseReady || updated.Status.Reason != "SessionReady" {
		t.Fatalf("unexpected status: %s/%s (%s)", updated.Status.Phase, updated.Status.Reason, updated.Status.Message)
	}
	if updated.Status.Endpoints == nil {
		t.Fatal("missing endpoints")
	}
	if updated.Status.Endpoints.InputPath != "/sessions/chrono-trigger/input" {
		t.Fatalf("input path = %q", updated.Status.Endpoints.InputPath)
	}
	if updated.Status.Endpoints.RTMPURL != "rtmp://127.0.0.1:1935/raw/chrono-trigger" {
		t.Fatalf("RTMP URL = %q", updated.Status.Endpoints.RTMPURL)
	}
	if updated.Status.Endpoints.WHEPPath != "/chrono-trigger/whep" {
		t.Fatalf("WHEP path = %q", updated.Status.Endpoints.WHEPPath)
	}
}

func TestReconcileReportsProgressDeadline(t *testing.T) {
	session := newSession()
	c := newTestClient(t, session, newBoundPVC())
	r := testReconciler(c, testScheme(t))
	reconcileSession(t, r, session)

	var deployment appsv1.Deployment
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &deployment); err != nil {
		t.Fatal(err)
	}
	deployment.Status.Conditions = []appsv1.DeploymentCondition{{
		Type:    appsv1.DeploymentProgressing,
		Status:  corev1.ConditionFalse,
		Reason:  "ProgressDeadlineExceeded",
		Message: "ReplicaSet has timed out progressing",
	}}
	if err := c.Status().Update(context.Background(), &deployment); err != nil {
		t.Fatalf("update Deployment status: %v", err)
	}

	reconcileSession(t, r, session)

	var updated v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Status.Phase != v1alpha1.PhaseFailed {
		t.Fatalf("phase = %s, want Failed", updated.Status.Phase)
	}
	if !strings.Contains(updated.Status.Message, "ProgressDeadlineExceeded") {
		t.Fatalf("message does not include the concrete failure: %q", updated.Status.Message)
	}
}

func TestReconcileReportsImagePullFailure(t *testing.T) {
	session := newSession()
	c := newTestClient(t, session, newBoundPVC())
	r := testReconciler(c, testScheme(t))
	reconcileSession(t, r, session)

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "chrono-trigger-test",
			Namespace: session.Namespace,
			Labels:    map[string]string{sessionLabel: session.Name},
		},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "session", Image: "missing"}}},
	}
	if err := c.Create(context.Background(), pod); err != nil {
		t.Fatal(err)
	}
	pod.Status = corev1.PodStatus{
		Phase: corev1.PodPending,
		ContainerStatuses: []corev1.ContainerStatus{{
			Name: "session",
			State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{
				Reason:  "ErrImageNeverPull",
				Message: `Container image "missing" is not present with pull policy of Never`,
			}},
		}},
	}
	if err := c.Status().Update(context.Background(), pod); err != nil {
		t.Fatalf("update Pod status: %v", err)
	}

	reconcileSession(t, r, session)

	var updated v1alpha1.RetroSession
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &updated); err != nil {
		t.Fatal(err)
	}
	if updated.Status.Phase != v1alpha1.PhaseFailed {
		t.Fatalf("phase = %s, want Failed", updated.Status.Phase)
	}
	if !strings.Contains(updated.Status.Message, "ErrImageNeverPull") {
		t.Fatalf("message does not include the image pull failure: %q", updated.Status.Message)
	}
}

func TestGBAUsesMgbaCore(t *testing.T) {
	session := newSession()
	session.Spec.Console = v1alpha1.ConsoleGBA
	session.Spec.ROM = "Pokemon - Emerald Version (USA, Europe).gba"
	c := newTestClient(t, session, newBoundPVC())
	r := testReconciler(c, testScheme(t))

	reconcileSession(t, r, session)

	var deployment appsv1.Deployment
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(session), &deployment); err != nil {
		t.Fatal(err)
	}
	if got := envMap(deployment.Spec.Template.Spec.Containers[0].Env)["CORE"]; got != "mgba" {
		t.Fatalf("GBA core = %q, want mgba", got)
	}
}

func TestValidateSessionRejectsUnsafeSpecs(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(*v1alpha1.RetroSession)
		message string
	}{
		{"unknown console", func(s *v1alpha1.RetroSession) { s.Spec.Console = "nes" }, "console"},
		{"absolute rom", func(s *v1alpha1.RetroSession) { s.Spec.ROM = "/etc/passwd" }, "relative"},
		{"parent traversal", func(s *v1alpha1.RetroSession) { s.Spec.ROM = "../secret.sfc" }, "segments"},
		{"dot segment", func(s *v1alpha1.RetroSession) { s.Spec.ROM = "./game.sfc" }, "segments"},
		{"empty save claim", func(s *v1alpha1.RetroSession) { s.Spec.SaveClaimName = "" }, "saveClaimName"},
		{"bad image", func(s *v1alpha1.RetroSession) { s.Spec.Image = "bad image" }, "image"},
		{"long pad name", func(s *v1alpha1.RetroSession) { s.Spec.PadName = strings.Repeat("x", 81) }, "padName"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			session := newSession()
			tt.mutate(session)
			err := validateSession(session)
			if err == nil || !strings.Contains(err.Error(), tt.message) {
				t.Fatalf("validateSession() = %v, want message containing %q", err, tt.message)
			}
		})
	}
}

func envMap(env []corev1.EnvVar) map[string]string {
	out := make(map[string]string, len(env))
	for _, item := range env {
		out[item.Name] = item.Value
	}
	return out
}

func envByName(env []corev1.EnvVar, name string) *corev1.EnvVar {
	for i := range env {
		if env[i].Name == name {
			return &env[i]
		}
	}
	return nil
}
