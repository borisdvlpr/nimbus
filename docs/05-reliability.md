# 05 — Reliability (reboot recovery, backup, rebuild test)

This is delivered by the `reliability` role, the last one in `ansible/bootstrap.yml`. Everything
here is host-level systemd — nothing runs in-cluster, so it costs nothing against the steady-state
RAM budget.

## What happens on a reboot

Most of a reboot takes care of itself before any new machinery gets involved:

- The Kind node container runs with `--restart=unless-stopped`, so Docker brings it back at boot
  and the control plane returns on its own.
- `tailscaled` is a system service, so the node rejoins the tailnet automatically.
- PVs are `hostPath` directories under `volumes_dir` (`/srv/nimbus/volumes`), so data reattaches
  at the same paths.

On top of that sits a health-gated unit, `nimbus-recovery.service`, which runs once at boot
(ordered after Docker and `tailscaled`). It nudges the node container up if it isn't running,
then waits up to `recovery.grace_seconds` — 300 by default — for the API server's `/healthz` to
go green. Most of the time it simply confirms things are healthy and exits, leaving a clean
record in the journal.

```bash
systemctl status nimbus-recovery.service     # active (exited) on success; failed if it gave up
journalctl -u nimbus-recovery.service -b     # what it did this boot
```

## If the cluster doesn't come back

**The secure default (`recovery.unattended: false`).** If the cluster is still unhealthy when
the grace period runs out, the unit deliberately does nothing destructive — it holds no secrets
and isn't in a position to rebuild anything safely. Instead it fails loudly, so
`systemctl status` shows `failed`, and logs the action to take:

```bash
# from your controller — re-running the bootstrap is idempotent and converges
scripts/install.sh
```

That covers the rare hard failure — a corrupted node container, etcd damage — by rebuilding from
git, without ever putting keys on the node. Because desired state lives in git and PVs sit on
fixed host paths, even a full recreate brings back both definitions and data, as long as the
disk itself survived.

**Unattended self-heal (`recovery.unattended: true`, opt-in).** If you'd rather the node recover
with no involvement from your controller at all, set this and re-run the bootstrap. On an
unrecoverable boot the unit will then recreate the cluster from the persisted
`/etc/nimbus/kind-cluster.yaml`, re-create the `sops-age` secret, and re-run `flux bootstrap` —
all on the node itself.

> **Know the trade-off.** Unattended mode requires the SOPS **age key** and the **git deploy
> key** to live on the node at rest, root-only under `/etc/nimbus/secrets` (mode 0600, dir 0700).
> On an SD card someone can physically remove, that is secrets-at-rest. The secure default stores
> nothing. Enable this only if you accept that. Switching back to `false` and re-running the
> bootstrap removes the persisted secrets.

Either way, a recreate only costs you in-memory etcd state. Flux rebuilds everything else.

## Backup (optional, off by default)

Valkey is a cache, so there's nothing there to persist. The only durable data is the Prometheus
TSDB (your metrics history) and any dashboards you built by hand in Grafana — both of which live
under `volumes_dir`. That's why the backup module is generic: it archives that directory rather
than dumping a database.

Turn it on in `ansible/group_vars/all.yml` and re-run the bootstrap:

```yaml
backup:
  enabled: true
  schedule: "daily"                 # systemd OnCalendar
  retain: 7                         # local archives to keep
  local_dir: "/var/backups/nimbus"
  dest: "backupuser@backup-host:/srv/nimbus-backups"   # optional tailnet target (rsync over Tailscale SSH)
```

A `nimbus-backup.timer` then runs `nimbus-backup.sh`, which tars `volumes_dir` into `local_dir`
and keeps the newest `retain` copies. If you set `dest`, it also rsyncs each archive to an
off-device host on your tailnet. Leave `enabled: false` (the default) and the timer is installed
but inert.

```bash
systemctl list-timers nimbus-backup.timer    # next run
sudo /usr/local/bin/nimbus-backup.sh         # run one now
```

The archive is crash-consistent, which Prometheus tolerates fine. If you want a genuinely
quiescent snapshot, scale the writers down first — e.g.
`kubectl -n monitoring scale statefulset/prometheus-kube-prometheus-stack-prometheus --replicas=0`,
back up, then scale back up.

### Restore

```bash
# stop the cluster so nothing is writing to the volume paths
kind delete cluster --name nimbus            # or scale the relevant workloads to 0

sudo tar -xzf /var/backups/nimbus/nimbus-volumes-YYYYMMDD-HHMMSS.tar.gz -C /srv/nimbus

# bring the cluster back; Flux reconciles and the restored data is picked up
scripts/install.sh
```

## The rebuild test (the acceptance test in `architecture.md` §6)

This is the one that proves the definition of done: wipe the device, follow the documented
bootstrap, and the cluster plus all apps come back from git. Worth running end to end after any
significant change.

1. **Wipe.** Remove the stale `nimbus` node from the Tailscale admin console, then re-flash
   Ubuntu per `docs/00-flash-os.md`. *(Maps to §6.1 step 1 — the only physical step.)*
2. **Secrets in place.** On the controller, confirm you have your age private key, the git deploy
   key, and a fresh single-use Tailscale auth key in the flashed cloud-init. *(§6.2 documented
   inputs.)*
3. **Config pinned and pushed.** Versions and `kind.node_image` pinned, `flux.git_url` set, repo
   pushed, and every `*.sops.yaml` encrypted. `scripts/install.sh` checks all of this before it
   runs. *(§6.1 steps 2–3.)*
4. **Provision.** Run `scripts/install.sh`. It handles the Ansible bootstrap and then waits for
   Flux. *(§6.1 steps 3–4.)*
5. **Verify green.** The finish line:

   ```bash
   export KUBECONFIG="$(pwd)/kubeconfig/nimbus.yaml"
   kubectl get nodes                     # Ready
   flux get kustomizations               # flux-system, infra-*, apps all Ready=True
   kubectl -n apps get pods              # valkey + web Running
   ssh nimbus@nimbus 'systemctl is-enabled ssh'          # masked (Tailscale SSH only)
   ssh nimbus@nimbus 'systemctl is-enabled nimbus-recovery.service'   # enabled
   ```

   *(Maps to the §6 acceptance test: cluster and all apps restored from git, reachable on the
   tailnet, with no undocumented manual steps.)*

One note on data: the rebuild restores declarative state. Application *data* only comes back if
you had the optional backup enabled and restore it (see the previous section). A bare wipe
without a backup returns with empty PVs — that's expected, and it still passes the acceptance
test.

## Troubleshooting — "the cluster won't come back"

- Start with `systemctl status nimbus-recovery.service` and
  `journalctl -u nimbus-recovery.service -b`. Did the unit run, and what did it report?
- `docker ps -a | grep nimbus-control-plane` — is the node container even there, and running?
  `docker start nimbus-control-plane` if it's stopped, `docker logs` if it's crash-looping.
- `cat /proc/cgroups | grep memory` should show `enabled = 1`. If it doesn't, the memory-cgroup
  cmdline never applied — see `docs/01-bootstrap.md`.
- If you're on the secure default and it's genuinely broken, run `scripts/install.sh` from the
  controller. That's the intended recovery path, and it needs no secrets on the node.

## Next

That closes out the planned build. The one optional piece left is the
[USB SSD migration](./06-ssd-migration.md) — flip `storage.mode` to `ssd`, copy `volumes_dir`
across, and recreate. Beyond that, if you ever outgrow a single node, the open question is the
Kind-vs-real-distro decision in `architecture.md` §4.3.
