# 02 — Infrastructure layer

With Flux running, the cluster starts pulling its own shared infrastructure from git: the
**Traefik** ingress data plane (driven by the **Gateway API**), **metrics-server**, the
**Gateway API CRDs**, and a static **StorageClass** for stateful workloads.

Nothing is exposed to you yet — that comes in step 04, when the apps attach their `HTTPRoute`s
to the Gateway you create here.

## What gets deployed

| Component | Version | Namespace | Notes |
|---|---|---|---|
| Gateway API CRDs | v1.5.1 (standard channel) | cluster-scoped | from the upstream project, pinned |
| Traefik | chart 41.0.0 / Proxy v3.7.5 | `traefik` | Gateway provider; auto-creates GatewayClass `traefik` + Gateway `traefik-gateway` |
| metrics-server | chart 3.13.1 / app v0.8.1 | `kube-system` | `--kubelet-insecure-tls` for Kind |
| StorageClass `nimbus-local` | — | cluster-scoped | static node-local volumes, `WaitForFirstConsumer`, `Retain` |

## Reconcile order

Flux applies these as three `Kustomization`s with explicit `dependsOn`, so the CRDs always land
before the controller that needs them (observability adds a fourth — see
`03-observability.md`):

```
infra-gateway-api ──▶ infra-controllers ──▶ (apps)
infra-storage ─────────────────────────────▶ (apps)
```

`infra-storage` has no dependencies of its own, so it reconciles in parallel.

## Routing model

Traffic comes in over the tailnet and reaches workloads through the Gateway API:

```
tailnet client ─▶ nimbus:80 (Tailscale IP)
                    │  Kind extraPortMapping  host:80 ─▶ node:80
                    ▼
                 Traefik pod  (hostPort 80 ─▶ container :8000, entrypoint "web")
                    │  Gateway "traefik-gateway", listener web (HTTP)
                    ▼
                 HTTPRoute (added per-app) ─▶ Service ─▶ Pod
```

It's HTTP-only for now. An HTTPS listener would need a TLS certificate (`certificateRefs`),
which is left for later — cert-manager or Tailscale Serve. That's an acceptable trade here
because the tailnet already encrypts every hop with WireGuard, so the `:80` traffic never
crosses an untrusted network in the clear.

The Gateway accepts `HTTPRoute`s from **all namespaces**
(`allowedRoutes.namespaces.from: All`), so apps can attach from their own namespace without you
granting each one individually.

## ⚠️ One-time: recreate the cluster

This step removes the control-plane `NoSchedule` taint from the Kind config
(`kind/cluster.yaml.j2` → `nodeRegistration.taints: []`) so the single node can actually
schedule workloads. Taints are applied at `kubeadm init`, which means **an existing cluster has
to be recreated** before the change takes effect:

```bash
# on the Pi (or via the bootstrap playbook, which recreates if absent)
kind delete cluster --name nimbus
ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml
```

Your data is safe through this. PersistentVolumes are backed by hostPaths under `/mnt/volumes`
on the host, and they reattach to the new cluster.

## Verify

```bash
# 1. Flux has reconciled every layer (all Ready=True)
flux get kustomizations

# 2. CRDs are installed
kubectl get crd | grep gateway.networking.k8s.io

# 3. GatewayClass is Accepted and the Gateway is Programmed
kubectl get gatewayclass traefik
kubectl get gateway -n traefik traefik-gateway

# 4. Traefik is running and bound to the node port
kubectl -n traefik get pods,svc
kubectl -n traefik get helmrelease traefik

# 5. metrics-server works (this is the Kind --kubelet-insecure-tls payoff)
kubectl top nodes
kubectl top pods -A

# 6. StorageClass exists
kubectl get storageclass nimbus-local
```

### Quick end-to-end smoke test (optional)

If you want proof that routing works before any real app exists, this deploys whoami behind an
HTTPRoute, checks it, and cleans up after itself:

```bash
kubectl create deploy whoami --image=traefik/whoami
kubectl expose deploy whoami --port=80

kubectl apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: whoami
  namespace: default
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
      sectionName: web
  hostnames: ["whoami.nimbus"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: whoami
          port: 80
YAML

# from a device on the tailnet:
curl -H 'Host: whoami.nimbus' http://nimbus/

kubectl delete httproute whoami; kubectl delete svc whoami; kubectl delete deploy whoami
```

## Troubleshooting

- **A `Kustomization` won't go Ready** — start with `flux get kustomizations`, then
  `kubectl -n flux-system describe kustomization <name>`. A stuck `infra-controllers` almost
  always means a HelmRelease is still installing or failing:
  `kubectl -n traefik describe helmrelease traefik`.
- **`kubectl top` says metrics aren't available** — give metrics-server about 60 seconds after
  a fresh install. If it sticks around, confirm the `--kubelet-insecure-tls` arg is really
  there: `kubectl -n kube-system get deploy metrics-server -o yaml | grep args -A3`.
- **The Gateway never becomes `Programmed`** — Traefik has to be running first, so check the
  Traefik pod logs in the `traefik` namespace.
- **Nothing answers on `:80`** — confirm the Traefik pod landed on the `ingress-ready` node,
  that `ports.web.hostPort` is 80 (`kubectl -n traefik get pod -o yaml | grep hostPort`), and
  that you recreated the cluster after the taint change above.

## Next

The shared plumbing is in place. Next comes the heaviest tenant on the Pi —
[observability](./03-observability.md): Prometheus, Grafana, and the exporters, trimmed to fit
the RAM budget.
