# Shared Kubernetes platform

This Kustomization contains the namespace, frontend, frontend RBAC, MediaMTX
and its Services. It is shared by SNES, GBA and other operator sessions.
The operator creates the emulator Deployment, input Service and audio relay
for each `RetroSession`.

For the local Minikube setup, first run `bash operator/deploy.sh` to create the
session Secret and operator, then run `bash deploy/kubernetes/local/deploy-platform.sh`.
The local script applies this Kustomization with the Minikube IP advertised
for WebRTC. It does not start or delete emulator sessions.

The base uses `127.0.0.1` as its placeholder WebRTC host. Other environments
should override `platform-settings.WEBRTC_HOST` in an overlay and supply the
`retro-session-secret` required by the frontend and session agents.
