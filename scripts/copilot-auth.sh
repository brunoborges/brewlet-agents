#!/usr/bin/env bash
# Opt-in: gives the Copilot CLI sidecar GitHub credentials so agents can call the model.
#
#   scripts/copilot-auth.sh             use $COPILOT_GITHUB_TOKEN, else the token of 'gh auth login'
#   scripts/copilot-auth.sh --remove    delete the stored credentials again
#
# The token goes into the github-token key of the Secret that only the copilot-cli sidecar reads;
# the agent containers never receive it. It travels over stdin, so it never appears in a process
# listing or in this repository. Pods are restarted because env vars are read at container start.
#
# Accepted tokens: a fine-grained PAT with the "Copilot Requests" permission, or an OAuth token
# (such as the one 'gh auth token' prints). Classic ghp_ PATs are not supported by Copilot.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl base64
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

ensure_agent_namespace
ensure_agent_secret

restart_agents() {
  local deploys
  deploys="$(kube -n "$AGENT_NAMESPACE" get deployments -o name 2>/dev/null || true)"
  [ -n "$deploys" ] || return 0
  log "restarting agents so their sidecars pick up the change"
  # shellcheck disable=SC2086  # one word per deployment name
  kube -n "$AGENT_NAMESPACE" rollout restart $deploys >/dev/null
  # shellcheck disable=SC2086
  kube -n "$AGENT_NAMESPACE" rollout status --timeout=5m $deploys >/dev/null
}

if [ "${1:-}" = "--remove" ]; then
  kube -n "$AGENT_NAMESPACE" patch secret "$AGENT_SECRET" --type=json \
    -p '[{"op":"remove","path":"/data/github-token"}]' >/dev/null 2>&1 || true
  ok "GitHub credentials removed from the cluster"
  restart_agents
  exit 0
fi
[ -z "${1:-}" ] || die "usage: $(basename "$0") [--remove]"

token="${COPILOT_GITHUB_TOKEN:-}"
source_name='$COPILOT_GITHUB_TOKEN'
if [ -z "$token" ]; then
  need gh
  token="$(gh auth token 2>/dev/null || true)"
  source_name="'gh auth token'"
fi
[ -n "$token" ] || die "no token found: set COPILOT_GITHUB_TOKEN or run 'gh auth login'"
case "$token" in
  ghp_*) die "classic personal access tokens (ghp_...) are not supported by Copilot; use a fine-grained PAT with the 'Copilot Requests' permission or an OAuth token" ;;
esac

printf '{"data":{"github-token":"%s"}}' "$(printf '%s' "$token" | base64 | tr -d '\n')" \
  | kube -n "$AGENT_NAMESPACE" patch secret "$AGENT_SECRET" --type=merge --patch-file=/dev/stdin >/dev/null
unset token
ok "stored the token from $source_name for the Copilot CLI sidecar (remove it with: make deauth)"
restart_agents
