# 03 — Observability

This step adds metrics and dashboards: a **trimmed kube-prometheus-stack** (Prometheus, Grafana,
node-exporter, kube-state-metrics, and the Prometheus Operator), reconciled by Flux, with
Grafana exposed through the shared Traefik Gateway you set up in step 02.

It's the single heaviest tenant on the Pi, which is why it arrives deliberately pared down.

## What gets deployed

| Component | Version | Notes |
|---|---|---|
| kube-prometheus-stack | chart 87.2.1 / operator v0.92.0 | namespace `monitoring` |
| Prometheus | (chart-pinned) | 1 replica, 60s scrape, 7d / 3GB retention, 4Gi static PV |
| Grafana | (subchart) | 1Gi static PV, admin via SOPS secret, exposed at `grafana.nimbus` |
| node-exporter + kube-state-metrics | (subcharts) | host + object metrics |
| Alertmanager | — | **disabled** |

### What was trimmed, and why

Alertmanager is off — there's no one to page in a homelab. The kube-controller-manager,
kube-scheduler, kube-proxy, and etcd scrapers are disabled too, because those components listen
on `127.0.0.1` inside Kind nodes; their ServiceMonitors would sit permanently "down" and just
add noise. Everything high-value still scrapes: node-exporter, kubelet/cAdvisor,
kube-state-metrics, CoreDNS, and the API server.

Beyond that, the scrape interval is relaxed to 60s and Prometheus memory is capped to fit the
RAM budget. `retentionSize: 3GB` is what guarantees the time-series database never fills its
4Gi volume.

## Storage

Two static, node-local volumes live under `/mnt/volumes`. Both use the `Retain` policy and
reattach after a cluster recreate:

- **Prometheus** gets a dedicated StorageClass, `nimbus-prometheus`, holding exactly one PV.
  The operator generates the PVC name itself, but with only one PV in that class the binding is
  unambiguous — so there's no name to guess.
- **Grafana** uses an explicit PVC (`grafana`), bound by `volumeName`/`claimRef` to its PV on
  the shared `nimbus-local` class.

## ⚠️ Do this before deploying: set the Grafana admin password

`grafana-admin.sops.yaml` ships as a **plaintext placeholder**. Put a real password in it and
encrypt it before committing:

```bash
# edit the admin-password value, then:
sops --encrypt --in-place infrastructure/observability/grafana-admin.sops.yaml
git add infrastructure/observability/grafana-admin.sops.yaml   # commit the ENCRYPTED file
```

Flux decrypts it at reconcile time using the cluster's `sops-age` key. Skip this and Grafana
comes up with the placeholder password.

## Verify

```bash
# 1. Flux reconciled the layer
flux get kustomizations | grep infra-observability
flux get helmreleases -n monitoring

# 2. Pods are up (operator, prometheus-0, grafana, kube-state-metrics, node-exporter)
kubectl -n monitoring get pods

# 3. Storage bound
kubectl -n monitoring get pvc
kubectl get pv | grep -E 'prometheus-data|grafana-data'

# 4. Prometheus targets are healthy (port-forward, then open /targets)
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
#   -> http://localhost:9090/targets   (expect no unexpected "down" targets)

# 5. metrics-server vs Prometheus: node/pod metrics flowing
kubectl top nodes
```

### Reach Grafana

Add `grafana.nimbus` to your tailnet DNS (or just send a `Host` header), then browse to it from
anywhere on the tailnet:

```bash
curl -H 'Host: grafana.nimbus' http://nimbus/api/health        # {"database":"ok",...}
# or just open http://grafana.nimbus/ in a browser on the tailnet
```

Log in as `admin` with the password you encrypted above. The bundled Kubernetes dashboards —
cluster, namespace, and pod compute, node-exporter, and the rest — are already loaded.

## Footprint

Rough resident memory, with requests lower and limits capping the bursts: Prometheus
~300–600Mi, Grafana ~96–192Mi, kube-state-metrics ~32–96Mi, operator ~64–128Mi, node-exporter
~16–48Mi.

This is the cluster's largest consumer by a wide margin. Keep it in mind before you add
anything else.

## Troubleshooting

- **The HelmRelease isn't Ready, or times out** — a first install pulls several images on a slow
  Pi, so the HelmRelease and Kustomization timeouts are set to 15m. Watch it with
  `kubectl -n monitoring describe helmrelease kube-prometheus-stack` and
  `kubectl -n monitoring get pods -w`.
- **The Prometheus PVC is stuck Pending** — check the PV exists and the class matches:
  `kubectl get pv prometheus-data` and `kubectl -n monitoring get pvc`. On a single node,
  binding only happens once the pod is scheduled.
- **Grafana rejects your login** — either you deployed before encrypting the secret (so it's
  running the placeholder password), or the secret keys don't match `admin-user` /
  `admin-password`. Check with
  `kubectl -n monitoring get secret grafana-admin -o yaml`.
- **Grafana 404s through the Gateway** — confirm the HTTPRoute attached and the backend Service
  name resolves: `kubectl -n monitoring get httproute grafana -o yaml` and
  `kubectl -n monitoring get svc kube-prometheus-stack-grafana`.
- **A target shows "down" in Prometheus** — if it's kube-controller-manager, scheduler, proxy,
  or etcd, that's expected on Kind, and exactly why they're disabled. Re-enabling them would
  mean exposing those components on 0.0.0.0.

## Deferred

Loki and log aggregation, Alertmanager with alert routing, and TLS for the Grafana route — it
rides the same HTTP-over-tailnet model as everything else for now.

## Next

Metrics are flowing. Time to put something on the cluster worth watching:
[the apps layer](./04-apps.md) — a Valkey cache and your own web app, exposed through the same
Gateway.
