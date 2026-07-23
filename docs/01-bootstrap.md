# 01 — Bootstrap (host → cluster → GitOps)

This takes the tailnet-reachable node you produced in `00-flash-os.md` and turns it into a
running single-node Kind cluster with Flux reconciling from git. The whole thing is idempotent,
so if something goes sideways you can just run it again and it converges.

## Before you start

- The node is on your tailnet and answers as `nimbus` (from `00-flash-os.md`).
- Your workstation — the Ansible controller — is on the same tailnet.
- On that controller you have:
  - Ansible, plus the collections: `ansible-galaxy install -r ansible/requirements.yml`
  - Your **age private key** file (e.g. `~/.config/sops/age/keys.txt`, from `age-keygen`)
  - A **git deploy key with write access** to your repo, for `flux bootstrap` — e.g.
    `~/.ssh/nimbus_deploy`
- This repository is pushed to your git remote, so Flux has something to pull.

## 1. Fill in the configuration

Open `ansible/group_vars/all.yml` and set:

- **Tool versions** under `versions:` (kind, kubectl, helm, flux, sops) to real releases, and
  `kind.node_image` to a digest. The tooling role refuses to run while the `x.y` placeholders
  are still in place.
- `flux.git_url` (the SSH URL if you're using ssh auth) and `flux.git_host`.
- The `bootstrap:` paths for your age key and deploy key — or pass them at the command line
  with `--extra-vars`.

Then edit `.sops.yaml` and replace the `age:` recipient with your age **public** key, and set
`ansible_host` in `ansible/inventory.ini` to the node's tailnet name (`nimbus`).

## 2. Push the repo

Flux pulls desired state from git, so anything you haven't pushed doesn't exist as far as the
cluster is concerned:

```bash
git add -A && git commit -m "nimbus: bootstrap" && git push
```

## 3. Run it

The easy path is the wrapper `scripts/install.sh`, which runs the preflight checks, does
everything below, and then waits for Flux to reconcile through the apps layer:

```bash
scripts/install.sh
```

If you'd rather drive the underlying steps yourself:

```bash
ansible-galaxy install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory.ini ansible/bootstrap.yml
```

Expect the play to **reboot the node once**, to activate the memory cgroup; it reconnects over
the tailnet on its own afterwards. Tasks that touch secrets run with `no_log`.

## 4. Verify

A kubeconfig lands at `kubeconfig/nimbus.yaml` (git-ignored), pointing at `https://nimbus:6443`.

```bash
export KUBECONFIG="$(pwd)/kubeconfig/nimbus.yaml"

kubectl get nodes                 # the node is Ready
kubectl get pods -A               # control plane + flux-system pods Running
flux check                        # controllers healthy
flux get kustomizations           # flux-system, infra-*, apps => Ready: True
```

And confirm the access hardening actually took:

```bash
ssh nimbus@nimbus 'systemctl is-enabled ssh'   # => masked (Tailscale SSH is the only path)
```

From here the `infra-*` and `apps` Kustomizations bring up Traefik, metrics-server, storage,
observability, and your apps on their own. Each layer has its own runbook in `docs/02`–`docs/05`.

## Idempotency & rebuilds

Re-running the playbook is always safe — it converges rather than starting over. The cluster is
only created if it's absent, and Flux bootstrap simply re-reconciles.

To rebuild from scratch: remove the stale `nimbus` node from the Tailscale admin console,
re-flash per `00-flash-os.md`, then run this again. Everything comes back from git. (Application
*data* is a separate question — see `architecture.md` §6.3.)

## Troubleshooting

- **Cluster won't form** — check `docker ps` and `kind export logs`, and confirm the memory
  cgroup actually applied (`cat /proc/cgroups | grep memory` should show `enabled` = 1).
- **Flux isn't reconciling** — `flux logs --all-namespaces` and `flux get sources git`. Usually
  it's the deploy key lacking access, or `flux.git_url` not being in SSH form.
- **kubectl TLS errors over the tailnet** — the API cert SANs need to include `nimbus` and the
  tailnet IP (both are set from the Kind template), and MagicDNS needs to resolve `nimbus`.
- **The node didn't come back after the reboot** — get to it via the console and check
  `tailscale status`, and that `tailscaled` is enabled.

## Next

The infrastructure, observability, and apps layers now reconcile automatically from git — walk
through them in `docs/02`–`docs/05`, starting with the
[infrastructure layer](./02-infrastructure.md). For reboot recovery and the full rebuild test,
see [`05-reliability.md`](./05-reliability.md).
