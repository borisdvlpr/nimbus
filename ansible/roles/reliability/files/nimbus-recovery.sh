#!/usr/bin/env bash
# nimbus reboot recovery — health-gated.
# Secure by default: verify the cluster came back and, if not, surface the failure so
# you can re-run scripts/install.sh from the controller. Optional unattended mode
# recreates the cluster and re-bootstraps Flux using node-persisted keys.
set -uo pipefail
ENV_FILE=/etc/nimbus/recovery.env
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

: "${CLUSTER_NAME:=nimbus}"
: "${NODE_CONTAINER:=${CLUSTER_NAME}-control-plane}"
: "${KUBECONFIG:=/root/.kube/config}"
: "${GRACE_SECONDS:=300}"
: "${UNATTENDED:=false}"
export KUBECONFIG

log() { logger -t nimbus-recovery -- "$*" 2>/dev/null || true; echo "nimbus-recovery: $*"; }

# 1) ensure the node container is running (restart=unless-stopped normally handles this)
running="$(docker inspect -f '{{.State.Running}}' "$NODE_CONTAINER" 2>/dev/null || echo missing)"
if [ "$running" != "true" ]; then
  log "node container '$NODE_CONTAINER' is '$running'; attempting docker start"
  docker start "$NODE_CONTAINER" >/dev/null 2>&1 || log "could not start container (may not exist yet)"
fi

# 2) wait for the API server to report healthy, up to the grace period
log "waiting up to ${GRACE_SECONDS}s for the API server to become healthy"
deadline=$(( $(date +%s) + GRACE_SECONDS ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl get --raw='/healthz' >/dev/null 2>&1; then
    log "cluster healthy — recovery complete"
    exit 0
  fi
  sleep 10
done

# 3) still unhealthy after the grace period
if [ "$UNATTENDED" != "true" ]; then
  log "ERROR: cluster not healthy after ${GRACE_SECONDS}s and unattended recovery is disabled."
  log "ACTION: re-run 'scripts/install.sh' from your controller (idempotent), or investigate on the node."
  exit 1
fi

# 4) unattended self-heal: recreate from the persisted config, then re-bootstrap Flux.
#    PVs live on fixed host paths and desired state is in git, so only in-memory etcd state is lost.
log "unattended recovery: recreating cluster '$CLUSTER_NAME'"
command -v kind >/dev/null 2>&1 || { log "kind not found"; exit 1; }
[ -f "${CLUSTER_CONFIG:-}" ] || { log "missing cluster config ${CLUSTER_CONFIG:-<unset>}"; exit 1; }
kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER_NAME" --config "$CLUSTER_CONFIG" --wait 180s || { log "kind create failed"; exit 1; }
docker update --restart=unless-stopped "$NODE_CONTAINER" >/dev/null 2>&1 || true
kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null 2>&1 || true

# recreate the SOPS age secret so the kustomize-controller can decrypt
if [ -f "${AGE_KEY:-}" ]; then
  kubectl create secret generic sops-age -n flux-system \
    --from-file=age.agekey="$AGE_KEY" --dry-run=client -o yaml | kubectl apply -f - \
    || log "sops-age secret apply failed"
else
  log "WARNING: age key not persisted; SOPS-encrypted resources will not decrypt"
fi

# re-bootstrap Flux against the repo
if [ "${GIT_AUTH:-ssh}" = "ssh" ] && [ -f "${DEPLOY_KEY:-}" ]; then
  flux bootstrap git --url="$GIT_URL" --branch="$GIT_BRANCH" --path="$GIT_PATH" \
    --components="$FLUX_COMPONENTS" --private-key-file="$DEPLOY_KEY" --silent \
    || { log "flux bootstrap failed"; exit 1; }
  log "unattended recovery complete"
  exit 0
else
  log "ERROR: unattended mode needs an ssh deploy key at ${DEPLOY_KEY:-<unset>}"
  exit 1
fi
