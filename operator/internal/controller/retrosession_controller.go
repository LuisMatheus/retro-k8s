package controller

import (
	"context"
	"fmt"
	"path"
	"reflect"
	"strconv"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	"k8s.io/utils/ptr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	v1alpha1 "github.com/matheus/retro-k8s/operator/api/v1alpha1"
)

const (
	sessionLabel   = "retro.k8s/session"
	managedByLabel = "app.kubernetes.io/managed-by"
	managedByValue = "retrosession-operator"
	partOfLabel    = "app.kubernetes.io/part-of"
	partOfValue    = "retro-k8s"
	nameLabel      = "app.kubernetes.io/name"
	nameValue      = "retrosession"
	fieldOwner     = "retrosession-operator"

	mediaRTSPPort = 8554

	conditionReady           = "Ready"
	conditionEmulatorReady   = "EmulatorReady"
	conditionInputAgentReady = "InputAgentReady"
	conditionMediaReady      = "MediaReady"
)

// SessionConfig controls the session Pods created by the operator.
type SessionConfig struct {
	DefaultImage     string
	RelayImage       string
	LocalMediaImage  string
	ImagePullPolicy  corev1.PullPolicy
	ROMLibraryPath   string
	ROMMountPath     string
	NodeInputRoot    string
	TokenSecretName  string
	MediaService     string
	MediaRTMPPort    int32
	SessionUID       int64
	SessionGID       int64
	InputGID         int64
	AgentPort        int32
	PadPrefix        string
	DefaultLogLevel  string
	DefaultMinHoldMS int32
}

// RetroSessionReconciler turns RetroSession resources into emulator
// Deployments and input Services.
type RetroSessionReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
	Config   SessionConfig
}

// +kubebuilder:rbac:groups=retro.k8s,resources=retrosessions,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=retro.k8s,resources=retrosessions/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=retro.k8s,resources=retrosessions/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=persistentvolumeclaims,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=events,verbs=create;patch

// Reconcile ensures the resources for one RetroSession exist and reports its
// readiness or a concrete failure reason.
func (r *RetroSessionReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var session v1alpha1.RetroSession
	if err := r.Get(ctx, req.NamespacedName, &session); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if !session.DeletionTimestamp.IsZero() {
		// The Deployment and Service are owned by the session and are
		// garbage-collected. The save PVC is deliberately not owned, so it
		// survives deletion and can be reused by a recreated session.
		return ctrl.Result{}, nil
	}

	if err := validateSession(&session); err != nil {
		return r.setPhase(ctx, &session, v1alpha1.PhaseFailed, "InvalidSpec", err.Error(), ctrl.Result{})
	}

	var pvc corev1.PersistentVolumeClaim
	err := r.Get(ctx, types.NamespacedName{Namespace: session.Namespace, Name: session.Spec.SaveClaimName}, &pvc)
	if err != nil {
		if apierrors.IsNotFound(err) {
			return r.setPhase(ctx, &session, v1alpha1.PhaseFailed, "SaveClaimNotFound",
				fmt.Sprintf("PersistentVolumeClaim %q does not exist; create it before starting the session", session.Spec.SaveClaimName),
				ctrl.Result{RequeueAfter: 30 * time.Second})
		}
		return ctrl.Result{}, err
	}
	claimPending := pvc.Status.Phase != corev1.ClaimBound

	deploymentGeneration, err := r.reconcileDeployment(ctx, &session)
	if err != nil {
		return r.setPhase(ctx, &session, v1alpha1.PhaseFailed, "DeploymentReconcileFailed", err.Error(), ctrl.Result{RequeueAfter: 30 * time.Second})
	}
	if err := r.reconcileService(ctx, &session); err != nil {
		return r.setPhase(ctx, &session, v1alpha1.PhaseFailed, "ServiceReconcileFailed", err.Error(), ctrl.Result{RequeueAfter: 30 * time.Second})
	}

	// Keep the emulator Deployment so the Pod can trigger binding for
	// WaitForFirstConsumer storage classes, but do not call the session Ready
	// until the claim is bound.
	if claimPending {
		return r.setPhase(ctx, &session, v1alpha1.PhasePending, "SaveClaimNotBound",
			fmt.Sprintf("PersistentVolumeClaim %q is %s; waiting for it to bind", pvc.Name, pvc.Status.Phase),
			ctrl.Result{RequeueAfter: 10 * time.Second})
	}

	result, err := r.refreshStatus(ctx, &session, deploymentGeneration)
	if err != nil {
		logger.Error(err, "could not update RetroSession status")
	}
	return result, err
}

// SetupWithManager registers watches for the session and its children.
func (r *RetroSessionReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&v1alpha1.RetroSession{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Watches(&corev1.Pod{}, handler.EnqueueRequestsFromMapFunc(r.mapPod)).
		Watches(&corev1.PersistentVolumeClaim{}, handler.EnqueueRequestsFromMapFunc(r.mapPVC)).
		Complete(r)
}

func (r *RetroSessionReconciler) mapPod(ctx context.Context, obj client.Object) []reconcile.Request {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return nil
	}
	name := pod.Labels[sessionLabel]
	if name == "" {
		return nil
	}
	return []reconcile.Request{{
		NamespacedName: types.NamespacedName{Namespace: pod.Namespace, Name: name},
	}}
}

func (r *RetroSessionReconciler) mapPVC(ctx context.Context, obj client.Object) []reconcile.Request {
	pvc, ok := obj.(*corev1.PersistentVolumeClaim)
	if !ok {
		return nil
	}
	var sessions v1alpha1.RetroSessionList
	if err := r.List(ctx, &sessions, client.InNamespace(pvc.Namespace)); err != nil {
		return nil
	}
	requests := make([]reconcile.Request, 0)
	for i := range sessions.Items {
		session := &sessions.Items[i]
		if session.Spec.SaveClaimName == pvc.Name {
			requests = append(requests, reconcile.Request{
				NamespacedName: types.NamespacedName{Namespace: session.Namespace, Name: session.Name},
			})
		}
	}
	return requests
}

func (r *RetroSessionReconciler) reconcileDeployment(ctx context.Context, session *v1alpha1.RetroSession) (int64, error) {
	desired := r.desiredDeployment(session)
	desired.TypeMeta = metav1.TypeMeta{APIVersion: appsv1.SchemeGroupVersion.String(), Kind: "Deployment"}
	if err := controllerutil.SetControllerReference(session, desired, r.Scheme); err != nil {
		return 0, fmt.Errorf("set owner on Deployment %s: %w", desired.Name, err)
	}

	var existing appsv1.Deployment
	err := r.Get(ctx, client.ObjectKeyFromObject(desired), &existing)
	created := apierrors.IsNotFound(err)
	if err == nil {
		if !metav1.IsControlledBy(&existing, session) {
			return 0, fmt.Errorf("Deployment %s/%s already exists and is not controlled by RetroSession %s", existing.Namespace, existing.Name, session.Name)
		}
	} else if !created {
		return 0, err
	}

	// Server-side apply keeps the operator from removing API-defaulted fields
	// on every reconcile.
	if err := r.Patch(ctx, desired, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return 0, fmt.Errorf("apply Deployment %s: %w", desired.Name, err)
	}
	if created {
		r.event(session, corev1.EventTypeNormal, "DeploymentCreated", "Created emulator Deployment %s", desired.Name)
	}
	return desired.Generation, nil
}

func (r *RetroSessionReconciler) reconcileService(ctx context.Context, session *v1alpha1.RetroSession) error {
	desired := r.desiredService(session)
	desired.TypeMeta = metav1.TypeMeta{APIVersion: corev1.SchemeGroupVersion.String(), Kind: "Service"}
	if err := controllerutil.SetControllerReference(session, desired, r.Scheme); err != nil {
		return fmt.Errorf("set owner on Service %s: %w", desired.Name, err)
	}

	var existing corev1.Service
	err := r.Get(ctx, client.ObjectKeyFromObject(desired), &existing)
	created := apierrors.IsNotFound(err)
	if err == nil {
		if !metav1.IsControlledBy(&existing, session) {
			return fmt.Errorf("Service %s/%s already exists and is not controlled by RetroSession %s", existing.Namespace, existing.Name, session.Name)
		}
	} else if !created {
		return err
	}

	if err := r.Patch(ctx, desired, client.Apply, client.FieldOwner(fieldOwner), client.ForceOwnership); err != nil {
		return fmt.Errorf("apply Service %s: %w", desired.Name, err)
	}
	if created {
		r.event(session, corev1.EventTypeNormal, "ServiceCreated", "Created input Service %s", desired.Name)
	}
	return nil
}

func (r *RetroSessionReconciler) refreshStatus(ctx context.Context, session *v1alpha1.RetroSession, appliedGeneration int64) (ctrl.Result, error) {
	var deployment appsv1.Deployment
	if err := r.Get(ctx, types.NamespacedName{Namespace: session.Namespace, Name: session.Name}, &deployment); err != nil {
		return ctrl.Result{}, err
	}

	var pods corev1.PodList
	if err := r.List(ctx, &pods, client.InNamespace(session.Namespace), client.MatchingLabels{sessionLabel: session.Name}); err != nil {
		return ctrl.Result{}, err
	}
	var pod *corev1.Pod
	for i := range pods.Items {
		candidate := &pods.Items[i]
		if !candidate.DeletionTimestamp.IsZero() {
			continue
		}
		if pod == nil || candidate.CreationTimestamp.After(pod.CreationTimestamp.Time) {
			pod = candidate
		}
	}

	oldStatus := session.Status.DeepCopy()
	oldPhase := session.Status.Phase
	session.Status.ObservedGeneration = session.Generation
	session.Status.DeploymentName = deployment.Name
	session.Status.ServiceName = inputServiceName(session.Name)
	session.Status.SaveClaimName = session.Spec.SaveClaimName
	session.Status.Endpoints = r.endpoints(session)
	session.Status.PodName = ""
	if pod != nil {
		session.Status.PodName = pod.Name
	}

	components := sessionComponentsFor(pod)

	phase := v1alpha1.PhasePending
	reason := "SessionNotReady"
	message := "Waiting for the emulator, input agent and media path to become ready"
	conditionStatus := metav1.ConditionFalse

	if failure := podFailure(pod, &deployment); failure != "" {
		phase = v1alpha1.PhaseFailed
		reason = "SessionFailed"
		message = failure
	} else if components.Emulator.Ready && components.InputAgent.Ready && components.Media.Ready &&
		deployment.Generation >= appliedGeneration && deployment.Status.ObservedGeneration >= deployment.Generation &&
		deployment.Status.Replicas == 1 && deployment.Status.UpdatedReplicas == 1 &&
		deployment.Status.ReadyReplicas == 1 && deployment.Status.AvailableReplicas == 1 {
		phase = v1alpha1.PhaseReady
		reason = "SessionReady"
		message = fmt.Sprintf("Emulator, input agent and media path are ready; input Service %s port %d", inputServiceName(session.Name), r.Config.AgentPort)
		conditionStatus = metav1.ConditionTrue
	} else {
		switch {
		case !components.Emulator.Ready:
			reason = "EmulatorNotReady"
			message = components.Emulator.Message
		case !components.InputAgent.Ready:
			reason = "InputAgentNotReady"
			message = components.InputAgent.Message
		case !components.Media.Ready:
			reason = "MediaNotReady"
			message = components.Media.Message
		default:
			reason = "DeploymentRolloutPending"
			message = "Waiting for the latest Deployment revision to become available"
		}
	}

	session.Status.Phase = phase
	session.Status.Reason = reason
	session.Status.Message = message
	meta.SetStatusCondition(&session.Status.Conditions, metav1.Condition{
		Type:               conditionReady,
		Status:             conditionStatus,
		Reason:             reason,
		Message:            message,
		ObservedGeneration: session.Generation,
	})
	setComponentCondition(&session.Status.Conditions, conditionEmulatorReady, session.Generation, components.Emulator)
	setComponentCondition(&session.Status.Conditions, conditionInputAgentReady, session.Generation, components.InputAgent)
	setComponentCondition(&session.Status.Conditions, conditionMediaReady, session.Generation, components.Media)

	if err := r.updateStatus(ctx, session, *oldStatus); err != nil {
		return ctrl.Result{}, err
	}
	if oldPhase != phase {
		eventType := corev1.EventTypeNormal
		if phase == v1alpha1.PhaseFailed {
			eventType = corev1.EventTypeWarning
		}
		r.event(session, eventType, reason, "%s", message)
	}

	// Requeue while the session is not Ready so media recovery is observed even
	// if the Pod watch misses an update. The Pod itself is never restarted just
	// because a readiness probe is failing.
	switch phase {
	case v1alpha1.PhaseReady:
		return ctrl.Result{}, nil
	case v1alpha1.PhaseFailed:
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	default:
		return ctrl.Result{RequeueAfter: 15 * time.Second}, nil
	}
}

// componentStatus is the readiness of one independent part of a session.
type componentStatus struct {
	Ready   bool
	Reason  string
	Message string
}

// sessionComponents groups the independently observed parts of a session.
type sessionComponents struct {
	Emulator   componentStatus
	InputAgent componentStatus
	Media      componentStatus
}

func sessionComponentsFor(pod *corev1.Pod) sessionComponents {
	emulator := containerComponent(pod, "emulator", "session")
	emulator.Reason = "EmulatorNotReady"
	if emulator.Ready {
		emulator.Reason = "EmulatorReady"
	}

	inputAgent := containerComponent(pod, "input agent", "input-health")
	inputAgent.Reason = "InputAgentNotReady"
	if inputAgent.Ready {
		inputAgent.Reason = "InputAgentReady"
	}

	media := containerComponent(pod, "media path", "audio-relay", "local-media")
	media.Reason = "MediaNotReady"
	if media.Ready {
		media.Reason = "MediaReady"
	}

	return sessionComponents{Emulator: emulator, InputAgent: inputAgent, Media: media}
}

// containerComponent reports whether every named container is Ready and, when
// it is not, a message suitable for RetroSession.status.
func containerComponent(pod *corev1.Pod, label string, names ...string) componentStatus {
	if pod == nil {
		return componentStatus{Message: fmt.Sprintf("Waiting for the session Pod to start the %s", label)}
	}
	statuses := make(map[string]corev1.ContainerStatus, len(pod.Status.ContainerStatuses))
	for _, status := range pod.Status.ContainerStatuses {
		statuses[status.Name] = status
	}

	problems := make([]string, 0, len(names))
	for _, name := range names {
		status, ok := statuses[name]
		if !ok {
			problems = append(problems, fmt.Sprintf("%s container has not started", name))
			continue
		}
		if status.Ready {
			continue
		}
		switch {
		case status.State.Waiting != nil:
			detail := status.State.Waiting.Reason
			if status.State.Waiting.Message != "" {
				detail += ": " + status.State.Waiting.Message
			}
			problems = append(problems, fmt.Sprintf("%s container is waiting: %s", name, detail))
		case status.State.Terminated != nil:
			problems = append(problems, fmt.Sprintf("%s container terminated with exit code %d", name, status.State.Terminated.ExitCode))
		default:
			problems = append(problems, fmt.Sprintf("%s readiness probe is failing", name))
		}
	}
	if len(problems) == 0 {
		return componentStatus{Ready: true, Message: fmt.Sprintf("The %s is ready", label)}
	}
	return componentStatus{Message: strings.Join(problems, "; ")}
}

func setComponentCondition(conditions *[]metav1.Condition, conditionType string, generation int64, status componentStatus) {
	conditionStatus := metav1.ConditionFalse
	if status.Ready {
		conditionStatus = metav1.ConditionTrue
	}
	meta.SetStatusCondition(conditions, metav1.Condition{
		Type:               conditionType,
		Status:             conditionStatus,
		Reason:             status.Reason,
		Message:            status.Message,
		ObservedGeneration: generation,
	})
}

func (r *RetroSessionReconciler) setPhase(ctx context.Context, session *v1alpha1.RetroSession, phase v1alpha1.SessionPhase, reason, message string, result ctrl.Result) (ctrl.Result, error) {
	oldStatus := session.Status.DeepCopy()
	oldPhase := session.Status.Phase
	session.Status.ObservedGeneration = session.Generation
	session.Status.Phase = phase
	session.Status.Reason = reason
	session.Status.Message = message
	session.Status.DeploymentName = session.Name
	session.Status.ServiceName = inputServiceName(session.Name)
	session.Status.SaveClaimName = session.Spec.SaveClaimName
	session.Status.Endpoints = r.endpoints(session)

	conditionStatus := metav1.ConditionFalse
	if phase == v1alpha1.PhaseReady {
		conditionStatus = metav1.ConditionTrue
	}
	meta.SetStatusCondition(&session.Status.Conditions, metav1.Condition{
		Type:               conditionReady,
		Status:             conditionStatus,
		Reason:             reason,
		Message:            message,
		ObservedGeneration: session.Generation,
	})
	// Component conditions describe the running Pod. They do not apply while a
	// session-level prerequisite (spec, claim or Deployment) is blocking it.
	for _, conditionType := range []string{conditionEmulatorReady, conditionInputAgentReady, conditionMediaReady} {
		meta.SetStatusCondition(&session.Status.Conditions, metav1.Condition{
			Type:               conditionType,
			Status:             metav1.ConditionFalse,
			Reason:             reason,
			Message:            message,
			ObservedGeneration: session.Generation,
		})
	}

	if err := r.updateStatus(ctx, session, *oldStatus); err != nil {
		return ctrl.Result{}, err
	}
	if oldPhase != phase {
		eventType := corev1.EventTypeNormal
		if phase == v1alpha1.PhaseFailed {
			eventType = corev1.EventTypeWarning
		}
		r.event(session, eventType, reason, "%s", message)
	}
	return result, nil
}

func (r *RetroSessionReconciler) updateStatus(ctx context.Context, session *v1alpha1.RetroSession, old v1alpha1.RetroSessionStatus) error {
	// A status write triggers another watch event. Skip unchanged updates so a
	// steady-state session does not reconcile in a tight loop.
	if reflect.DeepEqual(old, session.Status) {
		return nil
	}
	// MergeFrom sends only the status diff and does not carry the original
	// resourceVersion, so a concurrent kubectl apply does not cause a conflict.
	base := session.DeepCopy()
	base.Status = old
	return r.Status().Patch(ctx, session, client.MergeFrom(base))
}

func (r *RetroSessionReconciler) desiredDeployment(session *v1alpha1.RetroSession) *appsv1.Deployment {
	labels := r.labels(session)
	replicas := int32(1)
	image := session.Spec.Image
	if image == "" {
		image = r.Config.DefaultImage
	}
	minHold := r.Config.DefaultMinHoldMS
	if session.Spec.MinHoldMS != nil {
		minHold = *session.Spec.MinHoldMS
	}
	logLevel := session.Spec.LogLevel
	if logLevel == "" {
		logLevel = r.Config.DefaultLogLevel
	}
	romPath := path.Join(r.Config.ROMMountPath, session.Spec.ROM)
	rtspURL := fmt.Sprintf("rtsp://%s:%d/%s", r.Config.MediaService, mediaRTSPPort, session.Name)

	env := []corev1.EnvVar{
		{Name: "CORE", Value: coreForConsole(session.Spec.Console)},
		{Name: "ROM_PATH", Value: romPath},
		{Name: "STREAM_URL", Value: fmt.Sprintf("rtmp://127.0.0.1:%d/raw/%s", r.Config.MediaRTMPPort, session.Name)},
		{Name: "SAVE_PATH", Value: "/saves"},
		{Name: "VIDEO_DRIVER", Value: "gl"},
		{Name: "AUDIO_DRIVER", Value: "sdl2"},
		{Name: "SDL_AUDIODRIVER", Value: "dummy"},
		{Name: "RTMP_HOST", Value: "127.0.0.1"},
		{Name: "RTMP_PORT", Value: strconv.Itoa(int(r.Config.MediaRTMPPort))},
		{Name: "INPUT_AGENT", Value: "1"},
		{Name: "AGENT_PORT", Value: strconv.Itoa(int(r.Config.AgentPort))},
		{Name: "SESSION_ID", Value: session.Name},
		{Name: "DEVICE_NAME", Value: r.padName(session)},
		{Name: "INPUT_SOURCE_DIR", Value: "/host-input"},
		{Name: "INPUT_TOKEN_SECRET", ValueFrom: &corev1.EnvVarSource{
			SecretKeyRef: &corev1.SecretKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{Name: r.Config.TokenSecretName},
				Key:                  "INPUT_TOKEN_SECRET",
			},
		}},
		{Name: "ALLOWED_ORIGINS", Value: session.Spec.AllowedOrigins},
		{Name: "SHOW_FPS", Value: strconv.FormatBool(session.Spec.ShowFPS)},
		{Name: "LOG_LEVEL", Value: logLevel},
		{Name: "MIN_HOLD_MS", Value: strconv.Itoa(int(minHold))},
	}

	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      session.Name,
			Namespace: session.Namespace,
			Labels:    labels,
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Strategy: appsv1.DeploymentStrategy{Type: appsv1.RecreateDeploymentStrategyType},
			Selector: &metav1.LabelSelector{MatchLabels: map[string]string{sessionLabel: session.Name}},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					AutomountServiceAccountToken: ptr.To(false),
					SecurityContext: &corev1.PodSecurityContext{
						RunAsNonRoot:        ptr.To(true),
						RunAsUser:           ptr.To(r.Config.SessionUID),
						RunAsGroup:          ptr.To(r.Config.SessionGID),
						SupplementalGroups:  []int64{r.Config.InputGID},
						FSGroup:             ptr.To(r.Config.SessionGID),
						FSGroupChangePolicy: ptr.To(corev1.FSGroupChangeOnRootMismatch),
						SeccompProfile:      &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault},
					},
					Containers: []corev1.Container{{
						Name:            "session",
						Image:           image,
						ImagePullPolicy: r.Config.ImagePullPolicy,
						SecurityContext: &corev1.SecurityContext{Privileged: ptr.To(true)},
						Env:             env,
						Ports: []corev1.ContainerPort{{
							Name:          "input",
							ContainerPort: r.Config.AgentPort,
							Protocol:      corev1.ProtocolTCP,
						}},
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{Exec: &corev1.ExecAction{
								Command: []string{"/bin/sh", "-c", "grep -lqx retroarch /proc/[0-9]*/comm >/dev/null 2>&1"},
							}},
							InitialDelaySeconds: 5,
							PeriodSeconds:       5,
							FailureThreshold:    24,
						},
						VolumeMounts: []corev1.VolumeMount{
							{Name: "saves", MountPath: "/saves"},
							{Name: "roms", MountPath: r.Config.ROMMountPath, ReadOnly: true},
							{Name: "uinput", MountPath: "/dev/uinput"},
							{Name: "events", MountPath: "/host-input", ReadOnly: true},
							{Name: "session-input", MountPath: "/dev/input"},
							{Name: "udev", MountPath: "/run/udev/data", ReadOnly: true},
						},
					}, {
						Name:            "audio-relay",
						Image:           r.Config.RelayImage,
						ImagePullPolicy: r.Config.ImagePullPolicy,
						Command:         []string{"/bin/sh", "-c"},
						Args:            []string{fmt.Sprintf("while true; do ffmpeg -nostdin -loglevel warning -i rtmp://127.0.0.1:%d/raw/%s -map 0:v:0 -map 0:a:0 -c:v copy -c:a libopus -ar 48000 -ac 2 -f rtsp -rtsp_transport tcp %s; sleep 2; done", r.Config.MediaRTMPPort, session.Name, rtspURL)},
						SecurityContext: &corev1.SecurityContext{AllowPrivilegeEscalation: ptr.To(false), Capabilities: &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}}},
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{Exec: &corev1.ExecAction{
								Command: []string{"/bin/sh", "-c", fmt.Sprintf(
									`python3 -c 'import socket; socket.create_connection(("127.0.0.1", %d), timeout=1).close()' && streams=$(timeout 4 ffprobe -v error -rtsp_transport tcp -analyzeduration 0 -probesize 32 -show_entries stream=codec_type -of csv=p=0 %s) && printf '%%s\n' "$streams" | grep -qx video && printf '%%s\n' "$streams" | grep -qx audio`,
									r.Config.MediaRTMPPort, rtspURL,
								)},
							}},
							InitialDelaySeconds: 15,
							PeriodSeconds:       10,
							TimeoutSeconds:      7,
							FailureThreshold:    3,
						},
					}, {
						Name:            "local-media",
						Image:           r.Config.LocalMediaImage,
						ImagePullPolicy: r.Config.ImagePullPolicy,
						Env: []corev1.EnvVar{
							{Name: "MTX_RTMPADDRESS", Value: fmt.Sprintf("127.0.0.1:%d", r.Config.MediaRTMPPort)},
							{Name: "MTX_RTSP", Value: "no"},
							{Name: "MTX_WEBRTC", Value: "no"},
							{Name: "MTX_HLS", Value: "no"},
							{Name: "MTX_SRT", Value: "no"},
						},
						SecurityContext: &corev1.SecurityContext{AllowPrivilegeEscalation: ptr.To(false), Capabilities: &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}}},
					}, {
						Name:            "input-health",
						Image:           image,
						ImagePullPolicy: r.Config.ImagePullPolicy,
						Command:         []string{"/bin/sleep", "infinity"},
						SecurityContext: &corev1.SecurityContext{AllowPrivilegeEscalation: ptr.To(false), Capabilities: &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}}},
						ReadinessProbe: &corev1.Probe{
							ProbeHandler: corev1.ProbeHandler{Exec: &corev1.ExecAction{
								Command: []string{"/bin/bash", "-c", fmt.Sprintf("exec 3<>/dev/tcp/127.0.0.1/%d", r.Config.AgentPort)},
							}},
							InitialDelaySeconds: 2,
							PeriodSeconds:       5,
							FailureThreshold:    3,
						},
					}},
					Volumes: []corev1.Volume{
						{Name: "saves", VolumeSource: corev1.VolumeSource{PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: session.Spec.SaveClaimName}}},
						{Name: "roms", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: r.Config.ROMLibraryPath, Type: ptr.To(corev1.HostPathDirectory)}}},
						{Name: "uinput", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: path.Join(r.Config.NodeInputRoot, "dev/uinput"), Type: ptr.To(corev1.HostPathCharDev)}}},
						{Name: "events", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: path.Join(r.Config.NodeInputRoot, "dev/input"), Type: ptr.To(corev1.HostPathDirectory)}}},
						{Name: "session-input", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
						{Name: "udev", VolumeSource: corev1.VolumeSource{HostPath: &corev1.HostPathVolumeSource{Path: path.Join(r.Config.NodeInputRoot, "run/udev/data"), Type: ptr.To(corev1.HostPathDirectory)}}},
					},
				},
			},
		},
	}
}

func (r *RetroSessionReconciler) desiredService(session *v1alpha1.RetroSession) *corev1.Service {
	labels := r.labels(session)
	return &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      inputServiceName(session.Name),
			Namespace: session.Namespace,
			Labels:    labels,
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{sessionLabel: session.Name},
			Ports: []corev1.ServicePort{{
				Name:       "input",
				Port:       r.Config.AgentPort,
				TargetPort: intstr.FromString("input"),
				Protocol:   corev1.ProtocolTCP,
			}},
		},
	}
}

func (r *RetroSessionReconciler) labels(session *v1alpha1.RetroSession) map[string]string {
	return map[string]string{
		nameLabel:      nameValue,
		sessionLabel:   session.Name,
		managedByLabel: managedByValue,
		partOfLabel:    partOfValue,
	}
}

func (r *RetroSessionReconciler) padName(session *v1alpha1.RetroSession) string {
	if session.Spec.PadName != "" {
		return session.Spec.PadName
	}
	return fmt.Sprintf("%s %s", r.Config.PadPrefix, session.Name)
}

func (r *RetroSessionReconciler) endpoints(session *v1alpha1.RetroSession) *v1alpha1.SessionEndpoints {
	return &v1alpha1.SessionEndpoints{
		InputService: inputServiceName(session.Name),
		InputPort:    r.Config.AgentPort,
		InputPath:    fmt.Sprintf("/sessions/%s/input", session.Name),
		StreamPath:   session.Name,
		RTMPURL:      fmt.Sprintf("rtmp://127.0.0.1:%d/raw/%s", r.Config.MediaRTMPPort, session.Name),
		WHEPPath:     fmt.Sprintf("/%s/whep", session.Name),
	}
}

func (r *RetroSessionReconciler) event(session *v1alpha1.RetroSession, eventType, reason, messageFmt string, args ...interface{}) {
	if r.Recorder != nil {
		r.Recorder.Eventf(session, eventType, reason, messageFmt, args...)
	}
}

func inputServiceName(name string) string {
	return name + "-input"
}

func coreForConsole(console v1alpha1.Console) string {
	switch console {
	case v1alpha1.ConsoleGBA:
		return "mgba"
	default:
		return "snes9x"
	}
}

func containerRunning(pod *corev1.Pod, name string) bool {
	if pod == nil {
		return false
	}
	for _, status := range pod.Status.ContainerStatuses {
		if status.Name == name && status.State.Running != nil {
			return true
		}
	}
	return false
}

func validateSession(session *v1alpha1.RetroSession) error {
	if len(session.Name) > 57 {
		return fmt.Errorf("metadata.name must be at most 57 characters so the input Service name fits")
	}
	switch session.Spec.Console {
	case v1alpha1.ConsoleSNES, v1alpha1.ConsoleGBA:
	default:
		return fmt.Errorf("spec.console must be snes or gba")
	}
	if session.Spec.ROM == "" {
		return fmt.Errorf("spec.rom is required")
	}
	if strings.HasPrefix(session.Spec.ROM, "/") {
		return fmt.Errorf("spec.rom must be relative to the ROM library")
	}
	for _, part := range strings.Split(session.Spec.ROM, "/") {
		if part == "" || part == "." || part == ".." {
			return fmt.Errorf("spec.rom must not contain empty, . or .. path segments")
		}
	}
	if path.Clean(session.Spec.ROM) != session.Spec.ROM {
		return fmt.Errorf("spec.rom must be a clean relative path")
	}
	if session.Spec.SaveClaimName == "" {
		return fmt.Errorf("spec.saveClaimName is required")
	}
	if session.Spec.Image != "" && strings.ContainsAny(session.Spec.Image, " \t\r\n") {
		return fmt.Errorf("spec.image must be a container image reference without whitespace")
	}
	if session.Spec.PadName != "" && (len(session.Spec.PadName) > 80 || strings.ContainsAny(session.Spec.PadName, "\r\n")) {
		return fmt.Errorf("spec.padName must be at most 80 characters and must not contain newlines")
	}
	if session.Spec.MinHoldMS != nil && *session.Spec.MinHoldMS < 0 {
		return fmt.Errorf("spec.minHoldMS must be non-negative")
	}
	return nil
}

func podFailure(pod *corev1.Pod, deployment *appsv1.Deployment) string {
	if deployment != nil {
		for _, condition := range deployment.Status.Conditions {
			if condition.Type == appsv1.DeploymentProgressing && condition.Status == corev1.ConditionFalse && condition.Reason == "ProgressDeadlineExceeded" {
				// A readiness probe that stays false can trip the rollout
				// deadline even though the emulator is still running. Let the
				// component conditions explain the outage instead of declaring
				// the whole session failed.
				if containerRunning(pod, "session") {
					continue
				}
				return fmt.Sprintf("Deployment %s failed to progress (%s): %s", deployment.Name, condition.Reason, condition.Message)
			}
			if condition.Type == appsv1.DeploymentReplicaFailure && condition.Status == corev1.ConditionTrue {
				return fmt.Sprintf("Deployment %s cannot create replicas: %s", deployment.Name, condition.Message)
			}
		}
	}
	if pod == nil {
		return ""
	}
	if pod.Status.Phase == corev1.PodFailed {
		return fmt.Sprintf("Pod %s failed: %s", pod.Name, pod.Status.Message)
	}
	for _, status := range pod.Status.ContainerStatuses {
		if status.State.Waiting != nil {
			switch status.State.Waiting.Reason {
			case "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull",
				"InvalidImageName", "ImageInspectError", "CreateContainerConfigError",
				"CreateContainerError", "RunContainerError":
				return fmt.Sprintf("Container %s is waiting: %s: %s", status.Name, status.State.Waiting.Reason, status.State.Waiting.Message)
			}
		}
		if status.State.Terminated != nil && status.State.Terminated.ExitCode != 0 {
			return fmt.Sprintf("Container %s terminated with exit code %d: %s", status.Name, status.State.Terminated.ExitCode, status.State.Terminated.Message)
		}
	}
	for _, condition := range pod.Status.Conditions {
		if condition.Type == corev1.PodScheduled && condition.Status == corev1.ConditionFalse && condition.Reason == corev1.PodReasonUnschedulable {
			return fmt.Sprintf("Pod %s is unschedulable: %s", pod.Name, condition.Message)
		}
	}
	return ""
}
