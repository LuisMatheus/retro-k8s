# Profile API

An API-only Phoenix service backed by SQLite. Profiles organize player data;
they do not authenticate users. Keep this pilot on a trusted network.

## Run locally

From this directory, install Elixir and Erlang, then run:

```bash
mix setup
mix phx.server
```

The development database defaults to `../../profiles/profiles.db` relative to this
service directory. Set `DATABASE_PATH` to use a different file. Do not run this
local server at the same time as the Kubernetes API against the same database.

The API listens on `http://localhost:4000`. It has three endpoints:

```bash
curl http://localhost:4000/api/profiles
curl -X POST http://localhost:4000/api/profiles \
  -H 'content-type: application/json' -d '{"display_name":"Alice"}'
curl -X PATCH http://localhost:4000/api/profiles/PROFILE_ID \
  -H 'content-type: application/json' -d '{"display_name":"Alice 2"}'
```

Profiles have stable UUIDs and timestamps. Names must be non-empty and at most
50 characters. Duplicate names are allowed; the ID identifies the profile.
Run `mix test` to exercise the endpoints and database.

## Kubernetes pilot

The manifests under `k8s/` are **opt-in**: they
require the `retro-k8s` namespace, a locally loaded image and a Secret. They
create a single-replica API, ClusterIP Service and a PVC mounted at `/data`.
The `Recreate` strategy avoids two API Pods mounting the SQLite database during
an update. The container runs migrations on startup. This is not an HA setup.

From the repository root:

```bash
docker build -t retro-k8s-poc/profile-api:pilot services/profile-api
minikube -p minikube image load --daemon retro-k8s-poc/profile-api:pilot
# Only create this Secret once; keep its value private.
kubectl --context minikube -n retro-k8s create secret generic profile-api-secret \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)"
kubectl --context minikube apply -k services/profile-api/k8s
kubectl --context minikube -n retro-k8s rollout status deployment/profile-api
kubectl --context minikube -n retro-k8s port-forward service/profile-api 14000:4000
```

The profile database is stored in `profile-api-data`, separate from game save
claims. Deleting the Deployment does not remove that PVC. A PVC is not a backup.
The frontend has not yet been connected to this service. Data from earlier prototypes is not automatically migrated.

## Store the Minikube database in the repository profiles folder

The local overlay binds the PVC to a retained hostPath PV. First start Minikube,
then keep this command running in a terminal for as long as the API is running:

```bash
minikube -p minikube mount "$(pwd)/profiles:/mnt/retro-k8s-profiles"
```

Run it from the repository root. In a second terminal, build/load the image and
create the Secret as above, then apply the local overlay instead of the base:

```bash
kubectl --context minikube apply -k services/profile-api/k8s-local
kubectl --context minikube -n retro-k8s rollout status deployment/profile-api
```

The SQLite database and its journal files are now stored under `profiles/` on
the host and ignored by Git. The directory must be writable by container UID
1000. Restart the mount after a Minikube or mount-process restart; do not start
the API until the mount is active. This node-local setup is for Minikube, not
AKS or EKS. Back up the database separately.

If `profile-api-data` already exists and is bound to another volume, this
overlay cannot change it in place or migrate its contents. Back up and migrate
the existing data before replacing that claim; do not delete it blindly.
