# Frontend

The frontend serves the browser UI, discovers sessions and proxies their input
and WebRTC signaling. The input agent itself lives in `../input-agent/agent`;
the frontend shares its token-signing implementation.

- `browser/`: browser UI, controller handling and stream diagnostics.
- `frontend.py`: session discovery, public configuration and proxy endpoints.
- `server.py`: starts the HTTP server in Kubernetes or static mode.
- `Dockerfile`: builds the frontend image from the repository root.
- `tests/`: frontend and browser tests.

See the [project README](../README.md) for setup and test commands, and the
[operator README](../operator/README.md) for Kubernetes deployment.
