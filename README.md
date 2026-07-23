# nimbus

A reproducible, GitOps-managed single-node Kubernetes homelab on a Raspberry Pi 4 (4 GB, ARM64).

Git is the source of truth, and every remote path runs over **Tailscale**. The bar the project
holds itself to: **wipe the device, follow the documented bootstrap, and the cluster plus all
applications come back from this repository** — reachable on your tailnet, with no traditional
SSH, no public ports, and no undocumented manual steps.

It's a homelab, but the patterns are deliberately the ones you'd use on a real cluster:
declarative provisioning, pull-based GitOps, encrypted secrets in git, pinned versions, and a
runbook for every layer.

---

## Start here

New to the repo? Read in this order:

1. **[`docs/architecture.md`](docs/architecture.md)** — the design and, more usefully, the
   *reasoning*: why Kind, why Tailscale over a VPN, why the Gateway API instead of Ingress, and
   what the 4 GB RAM budget forces you to give up.
2. **The runbooks below**, in order. Each one is self-contained and ends by pointing at the next.

| # | Runbook | What it covers |
|---|---|---|
| 00 | [Flash the OS](docs/00-flash-os.md) | Ubuntu 24.04 + cloud-init, joining the tailnet. **The only physical step.** |
| 01 | [Bootstrap](docs/01-bootstrap.md) | Ansible: host config → Kind cluster → Flux. The main event. |
| 02 | [Infrastructure](docs/02-infrastructure.md) | Traefik + Gateway API, metrics-server, StorageClass. |
| 03 | [Observability](docs/03-observability.md) | Prometheus + Grafana, trimmed to fit the Pi. |
| 04 | [Apps](docs/04-apps.md) | Valkey cache + your web app, exposed through the Gateway. |
| 05 | [Reliability](docs/05-reliability.md) | Reboot recovery, optional backups, the rebuild test. |
| 06 | [SSD migration](docs/06-ssd-migration.md) | Optional: move write-heavy data off the SD card. |

---

## What's running

| Layer | Choice | Notes |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS (arm64) | headless, configured by cloud-init |
| Remote access | Tailscale | identity-based WireGuard mesh; Tailscale SSH replaces sshd |
| Runtime | Docker CE | |
| Kubernetes | Kind 0.31.0, node v1.35.5 | single node, control-plane taint removed |
| Provisioning | Ansible | push-based over Tailscale SSH — not Terraform |
| GitOps | Flux 2.8.5 | reconciles everything under `clusters/nimbus/` |
| Ingress | Traefik (chart 41.0.0) | **Gateway API** `HTTPRoute`, not classic Ingress |
| Secrets | SOPS + age | encrypted files committed; Flux decrypts in-cluster |
| Observability | kube-prometheus-stack 87.2.1 | Alertmanager off, 7d / 3GB retention |
| Apps | Valkey 9.1.0 + your app | in-memory cache (no PV) + multi-arch image from GHCR |
| Storage | static hostPath PVs | SD card today; USB SSD via one variable |

---

## Quickstart

Full detail lives in [`docs/00-flash-os.md`](docs/00-flash-os.md) and
[`docs/01-bootstrap.md`](docs/01-bootstrap.md) — this is the shape of it.

**1. Flash and join the tailnet** *(physical, once)*

Flash Ubuntu 24.04, then drop your Tailscale auth key into a **local, uncommitted** copy of
`cloud-init/user-data`. On first boot the node registers itself and answers to
`ssh nimbus@nimbus`.

**2. Configure and push**

```bash
scripts/secrets.sh                    # age keypair → .sops.yaml → encrypt the Grafana secret
# then, in ansible/group_vars/all.yaml:
#   - pin every version and kind.node_image
#   - set flux.git_url to your repo
# and in apps/web/: set your image, container port, and cache env-var names
git add -A && git commit -m "nimbus: configure" && git push
```

Pushing matters: **Flux reconciles the pushed commit, not your working tree.**

**3. Provision**

```bash
scripts/install.sh
```

Preflight checks → Ansible bootstrap → waits for Flux. The node reboots once along the way to
activate the memory cgroup and reconnects on its own. Then:

```bash
export KUBECONFIG="$(pwd)/kubeconfig/nimbus.yaml"
kubectl get nodes            # Ready
flux get kustomizations      # all Ready=True
```

Grafana lands at `http://grafana.nimbus/`, your app at `http://app.nimbus/`.

---

## What you provide

These are the only inputs. Everything else is in git.

- A **Tailscale account** with an ACL permitting `tag:nimbus` and your SSH access
- A **Tailscale auth key** — single-use, pre-authorized, non-ephemeral, tagged. Goes into the
  flashed cloud-init, never into git.
- Your **age private key**, for SOPS. The one secret that stays off-git.
- A **git deploy key** with write access, for `flux bootstrap`

No SSH key or password is configured anywhere: host access is Tailscale SSH, and the physical
console is the recovery path.

---

## How access works

Everything rides the tailnet — nothing is published to the internet.

- **Host shell** — `ssh nimbus@nimbus` via Tailscale SSH. Identity- and ACL-based, no keys to rotate.
- **Kubernetes API** — your kubeconfig points at the node's MagicDNS name, and the tailnet IP is
  in the API server's certificate SANs, so `kubectl` verifies TLS normally.
- **Apps and dashboards** — Traefik holds the host's `:80`, so any tailnet device can reach
  `app.nimbus` and `grafana.nimbus`.

Routes are HTTP-only by design: WireGuard already encrypts every hop, so nothing crosses an
untrusted network in the clear. TLS termination is deferred, not forgotten — see
`architecture.md`.

---

## Repository layout

```
ansible/            provisioning — bootstrap playbook, roles, and group_vars/all.yaml
kind/               cluster template (extraMounts, port mappings, API cert SANs)
clusters/nimbus/    Flux entrypoint — the Kustomizations and their dependsOn order
infrastructure/     controllers/ (Traefik, metrics-server), storage/, observability/
apps/               namespace + valkey/ + web/
scripts/            install.sh (provision), secrets.sh (SOPS/age setup)
docs/               architecture.md + runbooks 00–06
cloud-init/         headless first-boot config (auth key filled in locally, never committed)
```

**`ansible/group_vars/all.yaml` is the single source of user config.** Roles stay generic — set
values there rather than editing roles. It also documents itself; skim it before your first run.

---

## Design constraints worth knowing up front

**RAM is the binding constraint.** Steady state is roughly 2.6 GB of ~3.9 GB usable, leaving
about 1.3 GB of headroom. Every workload therefore **must** set memory limits, so a spike
OOM-kills one pod instead of wedging the node. Anything heavy you add later — a second stateful
app, Loki, Alertmanager — means trimming observability first.

**Git restores state, not data.** Namespaces, deployments, config, Helm releases, and your apps
all come back from this repo. Metrics history and application data do not — they were never in
git. That still satisfies the reproducibility bar. If you want data to survive a wipe, enable the
optional backup module in [`docs/05-reliability.md`](docs/05-reliability.md).

**The SD card is consumable.** Until you attach an SSD, etcd and the Prometheus TSDB write to
flash, which is why retention is short and size-capped. Moving to a USB SSD is one variable plus
[a runbook](docs/06-ssd-migration.md).
