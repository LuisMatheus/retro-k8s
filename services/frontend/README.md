# Frontend

The frontend serves the browser UI, discovers sessions and proxies their input
and WebRTC signaling. The input agent itself lives in `../runtimes/retroarch/input-agent/agent`;
the frontend shares its token-signing implementation.

- `browser/`: browser UI, controller handling and stream diagnostics.
- `frontend.py`: session discovery, public configuration and proxy endpoints.
- `server.py`: starts the HTTP server in Kubernetes or static mode.
- `Dockerfile`: builds the frontend image from the repository root.
- `tests/`: frontend and browser tests.

See the [project README](../../README.md) for setup and test commands, and the
[operator README](../operator/README.md) for Kubernetes deployment.

The profile panel uses the same-origin `/api/profiles` proxy. Set
`PROFILE_API_HOST` and optionally `PROFILE_API_PORT` (default 4000) to connect
it. Kubernetes sets the host to the `profile-api` Service. Profile selection
is stored in the browser and does not authenticate users or select save data.
