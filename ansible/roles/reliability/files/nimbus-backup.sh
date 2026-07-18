#!/usr/bin/env bash
# nimbus PV backup — archive volumes_dir locally (retain N) and optionally rsync each
# archive to an off-device tailnet target. Invoked by nimbus-backup.timer (off by default).
set -euo pipefail
ENV_FILE=/etc/nimbus/backup.env
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

: "${VOLUMES_DIR:?VOLUMES_DIR not set}"
: "${BACKUP_DIR:=/var/backups/nimbus}"
: "${RETAIN:=7}"

log() { logger -t nimbus-backup -- "$*" 2>/dev/null || true; echo "nimbus-backup: $*"; }

[ -d "$VOLUMES_DIR" ] || { log "volumes dir '$VOLUMES_DIR' not found"; exit 1; }
mkdir -p "$BACKUP_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
archive="$BACKUP_DIR/nimbus-volumes-$ts.tar.gz"

# Crash-consistent copy. Prometheus' TSDB tolerates this; Valkey is a cache with
# nothing to persist. For a quiescent snapshot, stop workloads first (see docs).
tar -czf "$archive" -C "$(dirname "$VOLUMES_DIR")" "$(basename "$VOLUMES_DIR")"
log "created $archive ($(du -h "$archive" | cut -f1))"

# local retention: keep the newest RETAIN archives
ls -1t "$BACKUP_DIR"/nimbus-volumes-*.tar.gz 2>/dev/null | tail -n +"$((RETAIN + 1))" | xargs -r rm -f || true

# optional off-device copy over the tailnet (rsync uses Tailscale SSH)
if [ -n "${DEST:-}" ]; then
  if rsync -a "$archive" "$DEST/"; then log "shipped to $DEST"; else log "WARNING: rsync to $DEST failed"; fi
fi
