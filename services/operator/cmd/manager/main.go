package main

import (
	"flag"
	"fmt"
	"os"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	v1alpha1 "github.com/matheus/retro-k8s/operator/api/v1alpha1"
	"github.com/matheus/retro-k8s/operator/internal/controller"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(v1alpha1.AddToScheme(scheme))
}

func main() {
	var (
		metricsAddr          string
		probeAddr            string
		namespace            string
		enableLeaderElection bool
		imagePullPolicy      string
		mediaRTMPPort        int
		agentPort            int
		defaultMinHoldMS     int
		config               controller.SessionConfig
	)

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "Address for the metrics endpoint.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "Address for health probes.")
	flag.StringVar(&namespace, "namespace", "retro-k8s", "Namespace to watch for RetroSession resources.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false, "Enable leader election for controller manager.")
	flag.StringVar(&config.DefaultImage, "default-image", "retro-k8s-poc/retroarch-input:pilot", "Default emulator image.")
	flag.StringVar(&config.LocalMediaImage, "local-media-image", "bluenviron/mediamtx:1", "MediaMTX image for per-session RTMP ingest.")
	flag.StringVar(&config.RelayImage, "relay-image", "retro-k8s-poc/frontend:pilot", "FFmpeg image for the per-session audio relay.")
	flag.StringVar(&imagePullPolicy, "image-pull-policy", "Never", "Image pull policy for session Pods.")
	flag.StringVar(&config.ROMLibraryPath, "rom-library-path", "/run/retro-k8s-input/roms", "Deprecated and ignored; ROMs are mounted from console-specific PVCs.")
	flag.StringVar(&config.ROMMountPath, "rom-mount-path", "/roms", "Mount path for the ROM library in session Pods.")
	flag.StringVar(&config.NodeInputRoot, "node-input-root", "/run/retro-k8s-input", "Node hostPath containing the attached input devices and udev data.")
	flag.StringVar(&config.TokenSecretName, "token-secret", "retro-session-secret", "Secret containing INPUT_TOKEN_SECRET.")
	flag.StringVar(&config.MediaService, "media-service", "mediamtx", "MediaMTX Service name.")
	flag.IntVar(&mediaRTMPPort, "media-rtmp-port", 1935, "Pod-local MediaMTX RTMP port.")
	flag.Int64Var(&config.SessionUID, "session-uid", 1000, "UID for session Pods.")
	flag.Int64Var(&config.SessionGID, "session-gid", 1000, "GID for session Pods.")
	flag.Int64Var(&config.InputGID, "input-gid", 104, "Supplementary input group for session Pods.")
	flag.IntVar(&agentPort, "agent-port", 8765, "Input agent and Service port.")
	flag.StringVar(&config.PadPrefix, "pad-prefix", "Retro-K8s Pad", "Prefix for generated virtual pad names.")
	flag.StringVar(&config.DefaultLogLevel, "default-log-level", "INFO", "Default input agent log level.")
	flag.IntVar(&defaultMinHoldMS, "default-min-hold-ms", 40, "Default minimum button hold in milliseconds.")
	flag.Parse()

	switch corev1.PullPolicy(imagePullPolicy) {
	case corev1.PullAlways, corev1.PullIfNotPresent, corev1.PullNever:
		config.ImagePullPolicy = corev1.PullPolicy(imagePullPolicy)
	default:
		fmt.Fprintf(os.Stderr, "invalid --image-pull-policy %q\n", imagePullPolicy)
		os.Exit(2)
	}
	if namespace == "" {
		fmt.Fprintln(os.Stderr, "--namespace is required")
		os.Exit(2)
	}
	if agentPort < 1 || agentPort > 65535 || mediaRTMPPort < 1 || mediaRTMPPort > 65535 {
		fmt.Fprintln(os.Stderr, "ports must be between 1 and 65535")
		os.Exit(2)
	}
	if config.SessionUID < 0 || config.SessionGID < 0 || config.InputGID < 0 {
		fmt.Fprintln(os.Stderr, "UID/GID values must be non-negative")
		os.Exit(2)
	}
	if defaultMinHoldMS < 0 {
		fmt.Fprintln(os.Stderr, "--default-min-hold-ms must be non-negative")
		os.Exit(2)
	}
	config.AgentPort = int32(agentPort)
	config.MediaRTMPPort = int32(mediaRTMPPort)
	config.DefaultMinHoldMS = int32(defaultMinHoldMS)

	ctrl.SetLogger(zap.New(zap.UseDevMode(false)))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme: scheme,
		Cache: cache.Options{
			DefaultNamespaces: map[string]cache.Config{namespace: {}},
		},
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "retrosession.retro.k8s",
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "create manager: %v\n", err)
		os.Exit(1)
	}

	reconciler := &controller.RetroSessionReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorderFor("retrosession-operator"),
		Config:   config,
	}
	if err := reconciler.SetupWithManager(mgr); err != nil {
		fmt.Fprintf(os.Stderr, "set up controller: %v\n", err)
		os.Exit(1)
	}
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		fmt.Fprintf(os.Stderr, "add health check: %v\n", err)
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		fmt.Fprintf(os.Stderr, "add readiness check: %v\n", err)
		os.Exit(1)
	}

	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		fmt.Fprintf(os.Stderr, "run manager: %v\n", err)
		os.Exit(1)
	}
}
