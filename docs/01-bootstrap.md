# 01 — Bootstrap (host → cluster → GitOps)

This takes the tailnet-reachable node from `00-flash-os.md` to a running single-node Kind
cluster with Flux reconciling from git. It is idempotent — re-running converges.

## Prerequisites

- The node is on your tailnet and reachable as `nimbus` (from `00-flash-os.md`).
- Your workstation (the Ansible controller) is on the same tailnet.
- On the controller:
  - Ansible installed, plus collections: `ansible-galaxy install -r ansible/requirements.yml`
  - Your **age private key** file (e.g. `~/.config/sops/age/keys.txt` from `age-keygen`)
  - A **git deploy key with write access** to your repo (for `flux bootstrap`), e.g. `~/.ssh/nimbus_deploy`
- This repository pushed to your git remote (so Flux can pull it).

## 1. Fill in the configuration

Edit `ansible/group_vars/all.yml`:

- **Pin tool versions** under `versions:` (kind, kubectl, helm, flux, sops) to real releases,
  and pin `kind.node_image` to a digest. The tooling role will not work with the `x.y` placeholders.
- Set `flux.git_url` (SSH URL for ssh auth) and `flux.git_host`.
- Set the `bootstrap:` paths (age key, deploy key) — or pass them with `--extra-vars`.

Edit `.sops.yaml`: replace the `age:` recipient with your age **public** key.

Edit `ansible/inventory.ini`: set `ansible_host` to the node's tailnet name (`nimbus`).

## 2. Push the repo

Flux pulls desired state from git, so commit and push before bootstrapping:

```bash
git add -A && git commit -m "nimbus: bootstrap" && git push
```

## 3. Run

The simplest path is the wrapper `scripts/install.sh`, which runs the preflight checks, the
steps below, and then waits for Flux to reconcile through the apps layer:

```bash
scripts/install.sh
```

Or run the underlying steps directly:

```bash
ansible-galaxy install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml
```

The play may **reboot the node once** (to activate the memory cgroup) and reconnect over the
tailnet automatically. Tasks handling secrets use `no_log`.

## 4. Verify

A kubeconfig is fetched to `kubeconfig/nimbus.yaml` (git-ignored), pointing at `https://nimbus:6443`.

```bash
export KUBECONFIG="$(pwd)/kubeconfig/nimbus.yaml"

kubectl get nodes                 # the node is Ready
kubectl get pods -A               # control plane + flux-system pods Running
flux check                        # controllers healthy
flux get kustomizations           # flux-system, infra-*, apps => Ready: True
```

Confirm access hardening:

```bash
ssh nimbus@nimbus 'systemctl is-enabled ssh'   # => masked (Tailscale SSH is the only path)
```

On the full repo, the `infra-*` and `apps` Kustomizations bring up Traefik, metrics-server,
storage, observability, and your apps automatically — each layer is documented in `docs/02`–`docs/05`.

## Idempotency & rebuilds

- Re-running the playbook is safe; it converges (the cluster is only created if absent, Flux
  bootstrap re-reconciles).
- To rebuild from scratch: remove the stale `nimbus` node from the Tailscale admin console,
  re-flash (`00-flash-os.md`), then re-run this. Everything is restored from git. (Application
  *data* is out of scope — see `architecture.md` §6.3.)

## Troubleshooting

- Cluster won't form: `docker ps`, `kind export logs`, check the memory cgroup actually applied
  (`cat /proc/cgroups | grep memory` shows `enabled` = 1).
- Flux not reconciling: `flux logs --all-namespaces`, `flux get sources git`, confirm the deploy
  key has access and `flux.git_url` is the SSH form.
- kubectl TLS error over the tailnet: confirm the API cert SANs include `nimbus` and the tailnet
  IP (they are set from the Kind template), and that MagicDNS resolves `nimbus`.
- Reboot didn't reconnect: `tailscale status` on the node (via console); ensure `tailscaled` is
  enabled.

## Next

After this bootstrap, the infrastructure, observability, and apps layers reconcile automatically
from git — see `docs/02`–`docs/05`. For reboot recovery and the full rebuild test, see
`docs/05-reliability.md`.
