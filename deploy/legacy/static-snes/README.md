# Legacy static SNES Minikube pilot

This is the original static pilot. Its Kustomization includes the shared
platform from `deploy/kubernetes/platform/` and adds one static RetroArch/input session.
For new sessions use the [operator](../../../operator/README.md).

The Pod mounts one user-supplied ROM directory read-only at `/roms` and a
`ReadWriteOnce` PVC at `/saves`. The signing secret is a Kubernetes Secret, and
the session Deployment uses one replica with the `Recreate` strategy.

## Prerequisites

- A running Docker-backed Minikube profile. The input probe must already pass;
  the pilot uses the same non-root, privileged container exception.
- The session and frontend images. Build them with `deploy.sh --build` if needed.
- A ROM and the values in `.env` (`GAMES_DIR`, `SNES_ROM`, `PUID`, `PGID`,
  `INPUT_GID`, `INPUT_TOKEN_SECRET`).

## Deploy

From the project root:

```bash
bash deploy/legacy/static-snes/deploy.sh
```

The local browser forwards can run automatically as a user service. The
provided unit assumes the checkout is at `~/Documents/retro-k8s`:

```bash
install -m 0644 deploy/kubernetes/local/retro-k8s-browser.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now retro-k8s-browser.service
```

Open http://127.0.0.1:18000 and click Unmute. `browser.sh` now forwards only
the frontend. The frontend discovers `RetroSession` resources with its service
account and proxies WHEP signaling and the input WebSocket on the same origin.
WebRTC media still uses UDP NodePort 30189 on the Minikube IP. An FFmpeg relay
copies H.264 video and converts AAC to Opus for the static `snes` playback path.
The static `snes` Deployment from this pilot is not listed by the
operator-aware frontend; create a `RetroSession` for browser play. The
development token issuer is unauthenticated, so keep the forward bound to
localhost.
The service reconnects its forwards after a Pod replacement. Minikube itself
must be running, and the temporary node attachments must be restored if the
Minikube node has restarted. Stop automatic forwarding with
`systemctl --user disable --now retro-k8s-browser.service`.

The script:

1. Tags the local images as `pilot` and loads them into the Minikube profile,
   along with `bluenviron/mediamtx:1`.
2. Generates `deploy/legacy/static-snes/generated/` (Secret values, session settings and the
   UID/GID patch). This directory and `.node-input-state` are ignored by Git.
3. Clones the host's live `/dev/uinput`, `/dev/input`, `/run/udev/data` and the
   ROM's parent directory into `/run/retro-k8s-input` on the Minikube node.
4. Applies the Kustomization and waits for the emulator process.

Useful options:

```bash
bash deploy/legacy/static-snes/deploy.sh --rom "$GAMES_DIR/snes/other-game.sfc"
bash deploy/legacy/static-snes/deploy.sh --build          # rebuild images first
bash deploy/legacy/static-snes/deploy.sh --no-attach      # node paths already attached
```

The default ROM is `$GAMES_DIR/snes/$SNES_ROM`. Only the ROM's parent
directory is exposed to the node, read-only. If you change ROM directories,
detach and reattach first:

```bash
bash deploy/kubernetes/local/attach-node-input.sh detach
bash deploy/legacy/static-snes/deploy.sh --rom /path/to/roms/other-game.sfc
```

## Verify

```bash
bash deploy/legacy/static-snes/verify.sh
```

The check passes when:

- RetroArch starts and opens the ROM from `/roms`.
- The named pilot pad (`Retro-K8s Pad snes-k8s`) exists and is reserved for
  player 1 in the generated RetroArch config.
- Writing to `/roms` is rejected.
- A marker written to `/saves` survives deleting and replacing the Pod.

You can inspect the session directly:

```bash
kubectl -n retro-k8s logs -f deployment/snes
kubectl -n retro-k8s get pvc snes-saves
kubectl -n retro-k8s port-forward svc/snes-input 8765:8765
```

## Stop

```bash
bash deploy/legacy/static-snes/teardown.sh
```

This removes the shared frontend and MediaMTX as well as the static workload,
and detaches the node input mounts. Stop other sessions first. The namespace and
save PVC are kept unless `--delete-data` is specified.

## Notes and limits

- The node attachment is a temporary pilot mechanism. It disappears when the
  Minikube node restarts; run `attach-node-input.sh attach` again. A production
  deployment needs a device plugin and per-session isolation.
- The emulator container is privileged because the probe showed that a regular
  Pod cannot open the attached `/dev/uinput`. It still runs as the non-root
  session user with the host input group.
- The save PVC starts empty. Existing host saves are not copied into it
  automatically; the pilot only proves that new saves survive Pod replacement.
- Browser access targets the local workstation. Remote access requires
  authentication, protected routes and appropriate WebRTC networking.
