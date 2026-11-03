package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Console is an emulated console supported by the session image.
// +kubebuilder:validation:Enum=snes;gba
type Console string

const (
	ConsoleSNES Console = "snes"
	ConsoleGBA  Console = "gba"
)

// SessionPhase is the high-level state of a RetroSession.
type SessionPhase string

const (
	PhasePending SessionPhase = "Pending"
	PhaseReady   SessionPhase = "Ready"
	PhaseFailed  SessionPhase = "Failed"
)

// RetroSessionSpec describes one emulator session.
type RetroSessionSpec struct {
	// Console selects the libretro core. Supported values are snes and gba.
	Console Console `json:"console"`

	// ROM is a path relative to the operator's read-only ROM library. It must
	// not be absolute and must not contain "." or ".." path segments.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:Pattern=`^[^/].*$`
	ROM string `json:"rom"`

	// SaveClaimName is an existing PersistentVolumeClaim in the session
	// namespace. The operator mounts it at /saves and never deletes it.
	// +kubebuilder:validation:MinLength=1
	SaveClaimName string `json:"saveClaimName"`

	// Image overrides the operator's default session image.
	// +optional
	Image string `json:"image,omitempty"`

	// PadName overrides the virtual gamepad name. It defaults to
	// "Retro-K8s Pad <session name>".
	// +optional
	PadName string `json:"padName,omitempty"`

	// MinHoldMS keeps short button taps held for at least this many
	// milliseconds. It defaults to the operator's configured value.
	// +optional
	// +kubebuilder:validation:Minimum=0
	MinHoldMS *int32 `json:"minHoldMS,omitempty"`

	// LogLevel overrides the input agent log level.
	// +optional
	LogLevel string `json:"logLevel,omitempty"`

	// ShowFPS enables RetroArch's on-stream frame counter.
	// +optional
	ShowFPS bool `json:"showFPS,omitempty"`

	// AllowedOrigins is a comma-separated WebSocket origin allowlist. An empty
	// value leaves the input agent's origin check disabled.
	// +optional
	AllowedOrigins string `json:"allowedOrigins,omitempty"`
}

// SessionEndpoints is the connection information a frontend needs for a
// session. The input service is in the same namespace as the RetroSession.
type SessionEndpoints struct {
	// InputService is the Service name for the input WebSocket.
	// +optional
	InputService string `json:"inputService,omitempty"`

	// InputPort is the Service port for the input WebSocket.
	// +optional
	InputPort int32 `json:"inputPort,omitempty"`

	// InputPath is the WebSocket path exposed by the input agent.
	// +optional
	InputPath string `json:"inputPath,omitempty"`

	// StreamPath is the MediaMTX playback path.
	// +optional
	StreamPath string `json:"streamPath,omitempty"`

	// RTMPURL is the session Pod-local RTMP publish URL (not reachable from other Pods).
	// +optional
	RTMPURL string `json:"rtmpURL,omitempty"`

	// WHEPPath is the MediaMTX WebRTC playback path.
	// +optional
	WHEPPath string `json:"whepPath,omitempty"`
}

// RetroSessionStatus reports the observed state of a session.
type RetroSessionStatus struct {
	// ObservedGeneration is the last generation processed by the operator.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Phase is Pending, Ready or Failed.
	// +optional
	Phase SessionPhase `json:"phase,omitempty"`

	// Reason is a short machine-readable reason for the phase.
	// +optional
	Reason string `json:"reason,omitempty"`

	// Message explains the current phase, including concrete failures.
	// +optional
	Message string `json:"message,omitempty"`

	// Conditions includes the standard Ready condition.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// Endpoints is the connection information for the frontend.
	// +optional
	Endpoints *SessionEndpoints `json:"endpoints,omitempty"`

	// DeploymentName is the emulator Deployment managed by this session.
	// +optional
	DeploymentName string `json:"deploymentName,omitempty"`

	// ServiceName is the input Service managed by this session.
	// +optional
	ServiceName string `json:"serviceName,omitempty"`

	// PodName is the current emulator Pod, when one exists.
	// +optional
	PodName string `json:"podName,omitempty"`

	// SaveClaimName is the existing claim mounted at /saves.
	// +optional
	SaveClaimName string `json:"saveClaimName,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=rs,scope=Namespaced
// +kubebuilder:printcolumn:name="Console",type=string,JSONPath=`.spec.console`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// RetroSession is a request for one emulator session.
type RetroSession struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   RetroSessionSpec   `json:"spec,omitempty"`
	Status RetroSessionStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// RetroSessionList is a list of RetroSession resources.
type RetroSessionList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []RetroSession `json:"items"`
}

func init() {
	SchemeBuilder.Register(&RetroSession{}, &RetroSessionList{})
}
