#!/usr/bin/env bash
#
# nimbus — one-shot provisioner (run on your workstation / Ansible controller).
#
# Encodes the documented bootstrap flow (docs/01-bootstrap.md) with preflight
# guards, then runs the Ansible playbook that takes the tailnet-reachable node
# to a running Kind cluster with Flux. Flux then reconciles everything in git —
# through the observability layer (increment 4) — on its own.
#
# This does NOT reimplement the Ansible roles. It orchestrates the steps a human
# would otherwise run by hand, and fails early on the mistakes that usually bite:
# unpinned versions, a placeholder git URL or age recipient, missing or
# unencrypted secrets, an unpushed repo.
#
# Prereqs (see docs/01-bootstrap.md): the node is on your tailnet as `nimbus`,
# this repo is pushed to flux.git_url, and your bootstrap secret files (age key,
# git deploy key) exist at the paths in ansible/group_vars/all.yaml.
#
# Usage:
#   scripts/install.sh                       # checks -> galaxy -> playbook -> wait
#   scripts/install.sh --check               # ansible dry-run (passed through)
#   scripts/install.sh --no-wait             # skip the post-run Flux readiness poll
#   scripts/install.sh --skip-preflight      # bypass guards (not recommended)
#   scripts/install.sh -- --limit nimbus --extra-vars "bootstrap.git_token=ghp_xxx"
#
set -euo pipefail

# --- locate repo root (this script lives in <repo>/scripts) ------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ALL_YML="ansible/group_vars/all.yaml"
SOPS_CFG=".sops.yaml"
KUBECONFIG_OUT="kubeconfig/nimbus.yaml"
PLAYBOOK="ansible/bootstrap.yaml"
INVENTORY="ansible/inventory.ini"
REQUIREMENTS="ansible/requirements.yaml"

DO_PREFLIGHT=1; DO_WAIT=1; PASSTHRU=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-preflight) DO_PREFLIGHT=0; shift ;;
    --no-wait)        DO_WAIT=0; shift ;;
    --)               shift; PASSTHRU+=("$@"); break ;;
    *)                PASSTHRU+=("$1"); shift ;;
  esac
done

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
ok()   { printf '%s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s!%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%s✗ %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }

# read a "key: value" scalar from a YAML file (strips quotes + inline comment)
yval() {
  grep -E "^[[:space:]]*$1:[[:space:]]" "$2" 2>/dev/null | head -1 \
    | sed -E "s/^[[:space:]]*$1:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]+$//"
}
expand_tilde() { local p="$1"; printf '%s' "${p/#\~/$HOME}"; }

# --- preflight ---------------------------------------------------------------
preflight() {
  echo "== preflight =="

  for bin in ansible-playbook ansible-galaxy git sed grep; do
    command -v "$bin" >/dev/null 2>&1 || die "missing required command: $bin"
  done
  ok "controller tooling present (ansible, git)"

  [[ -f "$ALL_YML" ]] || die "not at repo root? missing $ALL_YML"

  # versions + node image must be pinned (placeholders contain 'x.y' / '<digest>')
  if grep -nE 'x\.y|<digest>' "$ALL_YML" >/dev/null; then
    grep -nE 'x\.y|<digest>' "$ALL_YML" | sed 's/^/    /'
    die "unpinned values above in $ALL_YML — pin versions: and kind.node_image first"
  fi
  ok "tool versions and node image pinned"

  # flux.git_url must be set
  local git_url; git_url="$(yval git_url "$ALL_YML")"
  [[ -z "$git_url" || "$git_url" == *"<you>"* ]] && die "set flux.git_url in $ALL_YML (still has the <you> placeholder)"
  ok "flux.git_url set: $git_url"

  # .sops.yaml recipient must be a real age PUBLIC key
  [[ -f "$SOPS_CFG" ]] || die "missing $SOPS_CFG"
  grep -q 'age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY' "$SOPS_CFG" \
    && die "replace the placeholder age recipient in $SOPS_CFG with your age PUBLIC key"
  grep -qE 'age:[[:space:]]*age1[0-9a-z]+' "$SOPS_CFG" || warn "could not confirm an age1... recipient in $SOPS_CFG"
  ok ".sops.yaml has a real age recipient"

  # bootstrap secret files must exist on the controller
  local age_key; age_key="$(expand_tilde "$(yval age_key_path "$ALL_YML")")"
  [[ -n "$age_key" && -f "$age_key" ]] || die "age private key not found at: ${age_key:-<unset>} (bootstrap.age_key_path)"
  ok "age private key present: $age_key"

  local git_auth; git_auth="$(yval git_auth "$ALL_YML")"
  if [[ "$git_auth" == "ssh" ]]; then
    local dk; dk="$(expand_tilde "$(yval git_private_key_path "$ALL_YML")")"
    [[ -n "$dk" && -f "$dk" ]] || die "git deploy key not found at: ${dk:-<unset>} (bootstrap.git_private_key_path)"
    ok "git deploy key present: $dk"
  else
    warn "git_auth=$git_auth — pass the PAT at runtime: -- --extra-vars \"bootstrap.git_token=...\""
  fi

  # every *.sops.yaml secret must be ENCRYPTED before it reaches git / Flux
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if grep -q 'CHANGE_ME_THEN_SOPS_ENCRYPT' "$f" || ! grep -q '^sops:' "$f"; then
      die "secret is not encrypted: $f
    encrypt it first:  sops --encrypt --in-place \"$f\""
    fi
  done < <(find . -name '*.sops.yaml' -not -name '.sops.yaml' -not -path './.git/*' 2>/dev/null)
  ok "all *.sops.yaml secret files are SOPS-encrypted"

  # the web app image placeholder must be set, or the apps Kustomization never becomes Ready
  if grep -q 'ghcr.io/OWNER/REPO:TAG' apps/web/deployment.yaml 2>/dev/null; then
    die "set your image in apps/web/deployment.yaml (still the ghcr.io/OWNER/REPO:TAG placeholder) — see docs/04-apps.md"
  fi
  ok "web app image is set"

  # flux reconciles the PUSHED commit, not your working tree — warn, don't block
  if [[ -d .git ]]; then
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] \
      && warn "working tree has uncommitted changes — Flux applies the pushed commit, not local files"
    local up; up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    [[ -n "$up" && -n "$(git log "@{upstream}"..HEAD --oneline 2>/dev/null)" ]] \
      && warn "local commits not pushed to $up — push before bootstrapping so Flux sees them"
  fi
  echo
}

if [[ "$DO_PREFLIGHT" -eq 1 ]]; then preflight; else warn "preflight checks skipped"; fi

# --- galaxy + playbook -------------------------------------------------------
echo "== ansible-galaxy =="
ansible-galaxy install -r "$REQUIREMENTS"
echo

echo "== ansible-playbook (host -> cluster -> flux) =="
echo "   may reboot the node once for the memory cgroup, then reconnect over the tailnet"
ansible-playbook -i "$INVENTORY" "$PLAYBOOK" "${PASSTHRU[@]}"
echo

# --- post-run: wait for flux to reconcile through observability --------------
EXPECTED=(flux-system infra-gateway-api infra-controllers infra-storage infra-observability apps)

if [[ "$DO_WAIT" -ne 1 ]]; then ok "playbook complete (skipping Flux readiness wait)"; exit 0; fi

if ! command -v kubectl >/dev/null 2>&1 || [[ ! -f "$KUBECONFIG_OUT" ]]; then
  warn "kubectl not on this controller (or no $KUBECONFIG_OUT yet) — verify Flux yourself:"
  cat <<EOF
    export KUBECONFIG="\$(pwd)/$KUBECONFIG_OUT"
    flux get kustomizations      # expect Ready=True for: ${EXPECTED[*]}
EOF
  exit 0
fi

echo "== waiting for Flux Kustomizations (up to ~20m; observability is a large install on a Pi) =="
ready() {
  kubectl --kubeconfig "$KUBECONFIG_OUT" -n flux-system get kustomization "$1" \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null
}
deadline=$(( SECONDS + 1200 ))
while :; do
  pending=()
  for k in "${EXPECTED[@]}"; do
    [[ "$(ready "$k")" == "True" ]] || pending+=("$k")
  done
  [[ ${#pending[@]} -eq 0 ]] && { ok "all Kustomizations Ready: ${EXPECTED[*]}"; break; }
  (( SECONDS >= deadline )) && die "timed out waiting on: ${pending[*]}  (debug: flux get kustomizations)"
  printf '   waiting on: %s\n' "${pending[*]}"
  sleep 15
done

echo
ok "nimbus is provisioned (infrastructure + observability + apps)."
echo "   Grafana: http://grafana.nimbus/   (admin password from grafana-admin.sops.yaml)"
echo "   App:     http://app.nimbus/       (set your image + port in apps/web/ first)"
