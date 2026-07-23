# 04 — Apps (Valkey + web)

Now for the part the rest of the build exists to serve: your applications.

Everything under `apps/` is reconciled by the `apps` Flux Kustomization
(`clusters/nimbus/apps.yaml`), which depends on `infra-controllers` (for the Gateway) and
`infra-storage`, and already has SOPS decryption wired up. It all lands in the `apps` namespace.

There are two workloads:

- **Valkey** — an in-memory, Redis-compatible cache for the web app. Deliberately ephemeral: no
  persistence, no PersistentVolume, memory-bounded.
- **web** — your custom multi-arch Go app (an HTTP cache sitting in front of Valkey), exposed on
  the tailnet through the shared Traefik Gateway at `http://app.nimbus/`.

## Set these before it deploys

The manifests ship with obvious placeholders, and the `install.sh` preflight will let most of
them through — so check here rather than finding out from a failing reconcile:

| Where | Field | Set it to |
|---|---|---|
| `apps/web/deployment.yaml` | `image` | Your GHCR image. **Must include a `linux/arm64` variant** (build with `docker buildx --platform linux/arm64,linux/amd64`). Pin a tag or `@sha256`. |
| `apps/web/deployment.yaml` | `containerPort` (and the two probes) | The port your app listens on (placeholder `8080`). |
| `apps/web/configmap.yaml` | the `data:` keys | The env-var name(s) your app reads for its cache endpoint. Two common forms are provided (`REDIS_URL`, `REDIS_ADDR`) — rename to match, delete the rest. |

One thing that's easy to miss: the Service targets the container's named `http` port, so if you
rename that port, update `service.yaml` to match.

## Valkey: the cache pattern

Memory is bounded twice here, and that's on purpose:

- **`--maxmemory 128mb` with `--maxmemory-policy allkeys-lru`** caps the dataset itself and
  evicts least-recently-used keys once it's full. That's cache semantics — old entries make room
  for new ones instead of the process growing without limit.
- **The k8s memory limit of `192Mi`** is the process ceiling. It sits *above* `maxmemory` so the
  allocator has room to work. If you raise `maxmemory`, raise this with it.

Persistence is off (`--save ""`, `--appendonly no`). A cache is regenerable, so nothing is
written to disk and there's **no PersistentVolume to bind** — which is precisely why Valkey fits
a 4 GB SD-backed node better than Postgres would. It's cluster-internal too (`ClusterIP`, no
HTTPRoute), reached by the app at `valkey.apps.svc.cluster.local:6379`.

### Optional: require a password

The image ships with protected-mode off and we set no password. That's fine as it stands,
because the port is never exposed outside the pod network. If you'd rather require auth anyway:

1. Create `apps/valkey/auth.sops.yaml` (a Secret with `stringData.password`) and encrypt it with
   `sops --encrypt --in-place apps/valkey/auth.sops.yaml`, then add it to
   `apps/valkey/kustomization.yaml`.
2. Add `--requirepass $(VALKEY_PASSWORD)` to the Valkey args and source `VALKEY_PASSWORD` from
   the Secret; update the readiness probe to `valkey-cli -a $VALKEY_PASSWORD ping`.
3. Give the web app the same password (add it to `web-config` as a Secret ref) and make sure
   your app actually sends AUTH.

Because the `apps` Kustomization already sets `decryption.provider: sops`, the encrypted Secret
decrypts at reconcile time with no further wiring — the same mechanism behind the Grafana admin
secret.

## web: private image (optional)

If your GHCR package is private, the node needs pull credentials:

1. Create a `dockerconfigjson` Secret (using a GHCR PAT with `read:packages`), save it as
   `apps/web/pull-secret.sops.yaml`, and `sops --encrypt --in-place` it.
2. Add it to `apps/web/kustomization.yaml`, then add `imagePullSecrets: [{name: <secret>}]` to
   the Deployment's pod spec.

A public package needs none of this, which is the default.

## Reconcile order

Nothing new is added to Flux here — the existing `apps` Kustomization reconciles the whole
`apps/` tree. It already depends on `infra-controllers` (so the `traefik-gateway` and the Gateway
API CRDs exist before the HTTPRoute does) and on `infra-storage`, and it already decrypts SOPS
secrets. So once infrastructure is green, the apps land on their own.

## RAM

Valkey (capped) plus a small Go app fit comfortably in what's left of the budget — see
`architecture.md` §5.1. Roughly `~150 MB` for Valkey against its `192Mi` limit, and `~40 MB` for
web against `64Mi`. Both carry memory limits, so a spike gets contained instead of pressuring
the whole node.

## Verify

```bash
export KUBECONFIG="$(pwd)/kubeconfig/nimbus.yaml"

flux get kustomizations apps            # Ready: True
kubectl -n apps get pods                # valkey + web Running and Ready
kubectl -n apps get httproute web       # Accepted / ResolvedRefs True

# cache reachable from inside the cluster
kubectl -n apps exec deploy/valkey -- valkey-cli ping     # PONG

# app reachable over the tailnet (after adding app.nimbus to tailnet DNS)
curl -s http://app.nimbus/ -o /dev/null -w '%{http_code}\n'
# or without DNS:
curl -s -H 'Host: app.nimbus' http://nimbus/ -o /dev/null -w '%{http_code}\n'
```

If `web` never goes Ready, the usual culprits are the image and the port. Check the image really
has an arm64 variant — `kubectl -n apps describe pod` will show `exec format error` or
`no match for platform` if it doesn't — and that the container port matches what your app
actually listens on.

## Next

The stack is complete and serving. What's left is making it survive the real world:
[reliability hardening](./05-reliability.md) — reboot recovery (a systemd-gated cluster recreate
plus a Flux re-bootstrap), an optional off-device backup, and a rebuild checklist mapped to the
acceptance test in `architecture.md` §6.
