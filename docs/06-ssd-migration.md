# 06 — USB SSD migration (optional)

This one moves the write-heavy data off the SD card and onto an external USB SSD. It's the
natural close to the SD-wear thread in `architecture.md` §5.3: etcd and the Prometheus TSDB —
the two things hardest on flash — end up on a disk with far better random IOPS and endurance.

It's genuinely optional. Nothing needs it to run.

It's also the one procedure the automation deliberately leaves manual, because it's one-time,
stateful, and destructive if you fumble it. The storage layer is already SSD-ready, so flipping
two flags is enough to make Ansible mount the disk and point Docker at it. What this runbook
really gives you is the safe *ordering* and the *data migration* that flag-flipping alone won't
do.

## What moves, and how

| Data | Lives on (local) | Lives on (ssd) | Moved by |
|---|---|---|---|
| PV data — Prometheus TSDB, Grafana | `/srv/nimbus/volumes` | `/mnt/data/volumes` | **you** (`rsync`, step 5) — this is the only data worth preserving |
| etcd, image layers, node container fs | `/var/lib/docker` | `/mnt/data/docker` | rebuilt: etcd from git via Flux, images re-pulled |
| The mount + Docker data-root config | — | — | the playbook, once you set the flags (step 6–7) |

The distinction that matters: relocating Docker's data-root takes care of etcd and images, but
the PV data sits under `volumes_dir`, which Kind bind-mounts into the node via `extraMounts`.
That's *not* under the data-root, so it has to be copied separately. Everything else gets rebuilt
from git and upstream registries, so it doesn't need migrating at all.

The values below match the `storage.ssd` defaults in `ansible/group_vars/all.yml`: label
`NIMBUS_SSD`, mount point `/mnt/data`, filesystem `ext4`. Adjust the commands if you change them.

## Before you start

- **Hardware.** Use a **blue USB 3.0** port and a decent USB-SATA adapter with **UASP** support.
  Some bridge chips (certain JMicron and ASMedia ones) need a UAS quirk to stay stable — if the
  disk drops out under load, add `usb-storage.quirks=VID:PID:u` to `/boot/firmware/cmdline.txt`
  (find `VID:PID` with `lsusb`). Make sure the drive is adequately powered.
- **Back up first** (step 0). The procedure is non-destructive if you follow it, but a backup
  makes rollback trivial.
- **Budget the time.** You're looking at an `rsync` of your TSDB plus a full cluster recreate.
  On a slow link, re-pulling the observability images is the long pole.
- Run everything on the node over Tailscale SSH (`ssh nimbus@nimbus`), except the final re-run,
  which you invoke from your controller.

## 0. Back up

If you enabled the backup module in `docs/05-reliability.md`, take one now:

```bash
sudo /usr/local/bin/nimbus-backup.sh
```

If not, archive the volume directory by hand:

```bash
sudo tar -czf /root/nimbus-volumes-premigration.tar.gz -C /srv/nimbus volumes
```

## 1. Attach and identify the disk

Plug the SSD into a USB 3.0 port, then find its device node:

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT
```

You're looking for the disk with `TRAN=usb` and the right size — probably something like `sda`.
**Confirm this is the SSD and not your boot media**, because the next step erases it. Everything
below uses `/dev/sdX`; substitute the real node.

## 2. Partition, format, label (manual)

The automation mounts the SSD *by label*, but it will never partition or format a disk for you —
that stays manual precisely so no disk is ever wiped automatically.
(`storage.ssd.format_if_unformatted` is a reserved flag, not yet wired up; don't rely on it.)

```bash
# one partition spanning the disk
sudo parted -s /dev/sdX mklabel gpt
sudo parted -s /dev/sdX mkpart primary ext4 0% 100%

# format ext4 with the label the role mounts by (must equal storage.ssd.fs_label)
sudo mkfs.ext4 -L NIMBUS_SSD /dev/sdX1

# verify the label is set
sudo blkid /dev/sdX1        # expect: LABEL="NIMBUS_SSD" TYPE="ext4"
```

## 3. Mount it and create the target directories

```bash
sudo mkdir -p /mnt/data
sudo mount LABEL=NIMBUS_SSD /mnt/data
sudo mkdir -p /mnt/data/volumes /mnt/data/docker
```

## 4. Quiesce the cluster

Stopping the cluster releases the bind mount and halts writes. Your PV data on the SD card is
untouched by this — the only thing lost is in-cluster etcd state, which Flux rebuilds from git.

```bash
kind delete cluster --name nimbus
```

## 5. Migrate the PV data (the one copy that matters)

Copy the existing volume data — Prometheus history, any dashboards you made by hand — onto the
SSD. Watch the trailing slashes; they're what makes this copy the *contents* into the target.

```bash
sudo rsync -aHAX --info=progress2 /srv/nimbus/volumes/ /mnt/data/volumes/

# sanity check: the same subdirectories (prometheus, grafana, ...) now exist on the SSD
ls -la /mnt/data/volumes
```

> Skipping this step is a perfectly valid choice — you'll just start on the SSD with empty PVs
> and lose your metrics history. Everything else still comes back.

Don't try to `rsync` `/var/lib/docker`, though. Overlay2's layout doesn't copy cleanly, and it's
unnecessary anyway: Docker and Kind rebuild it. The data-root only needs to *point* at the SSD,
which the next steps handle.

## 6. Flip the flags

In `ansible/group_vars/all.yml`, switch storage to SSD mode and enable the data-root relocation:

```yaml
storage:
  mode: ssd                          # was: local
  base_dir: /srv/nimbus
  volumes_subdir: volumes
  relocate_docker_data_root: true    # was: false — moves Docker's data-root onto the SSD
  ssd:
    fs_label: NIMBUS_SSD
    mount_point: /mnt/data
    filesystem: ext4
    format_if_unformatted: false
```

Commit and push, keeping the repo the source of truth:

```bash
git commit -am "feat(storage): switch to ssd mode" && git push
```

## 7. Re-run the bootstrap

From your controller:

```bash
scripts/install.sh
```

In role order, this now mounts the SSD at `/mnt/data` and writes an `fstab` entry so it survives
reboots; rewrites `daemon.json` with `"data-root": "/mnt/data/docker"` and restarts Docker onto
the empty SSD data-root; recreates the Kind cluster — absent since step 4 — with the `extraMount`
hostPath now resolving to `/mnt/data/volumes`; re-bootstraps Flux; and waits for reconciliation.
Prometheus' PV binds to the migrated TSDB, so your history survives.

## 8. Verify

```bash
findmnt /mnt/data                                   # SSD mounted (ext4, NIMBUS_SSD)
grep NIMBUS_SSD /etc/fstab                           # persists across reboot
docker info --format '{{.DockerRootDir}}'            # /mnt/data/docker
df -h /mnt/data                                      # volume + docker usage now on the SSD

export KUBECONFIG="$(pwd)/kubeconfig/nimbus.yaml"    # from the controller
kubectl get nodes                                    # Ready
flux get kustomizations                              # all Ready=True
```

If you migrated the TSDB, open Grafana and confirm the dashboards show data from *before* the
migration. That's your proof the PV data came across intact.

## 9. Reclaim SD space (optional — and only once you're happy)

The old copies on the SD card are now unused. Removing them frees space and makes certain nothing
writes back to flash. Hold off on this until you've confirmed the SSD works and you no longer
want the easy rollback below.

```bash
sudo rm -rf /srv/nimbus/volumes/*        # old PV data (now on the SSD)
sudo rm -rf /var/lib/docker/*            # old Docker data-root (Docker now uses the SSD)
```

## Rollback

Because the migration copies rather than moves — right up until step 9 — reverting is
straightforward. Set `storage.mode: local` and `relocate_docker_data_root: false` in `all.yml`,
remove the SSD's `fstab` line, then:

```bash
kind delete cluster --name nimbus
scripts/install.sh
```

You're back on the SD card with whatever data it still holds. This is exactly why step 9 is
deferred: until you run it, the SD copy is intact and rollback needs nothing else. (If you
already reclaimed the SD, restore from the step 0 backup instead.)

## Notes

- **Backups** follow the SSD automatically. `volumes_dir` resolves to `/mnt/data/volumes` in SSD
  mode, so `nimbus-backup.sh` archives the SSD copy with no change on your part.
- **Rebooting** is unaffected: the `fstab` entry mounts the SSD before Docker starts, and
  `nimbus-recovery.service` (`docs/05-reliability.md`) health-gates the cluster as usual.
- This is the last of the planned work. Beyond it, the main open architectural question is the
  Kind-vs-real-distro decision in §4.3, which only matters if you outgrow a single node.
