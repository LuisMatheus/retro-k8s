// Package v1alpha1 contains the RetroSession API.
// +kubebuilder:object:generate=true
// +groupName=retro.k8s
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is the API group and version for RetroSession resources.
	GroupVersion = schema.GroupVersion{Group: "retro.k8s", Version: "v1alpha1"}

	// SchemeBuilder registers the API types with a runtime scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the API types to a runtime scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
