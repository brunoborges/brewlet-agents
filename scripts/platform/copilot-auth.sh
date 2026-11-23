#!/usr/bin/env bash
# Opt-in: gives the Copilot CLI sidecar GitHub credentials so agents can call the model.
#
#   export COPILOT_GITHUB_TOKEN="$(gh auth token --hostname github.com)"
#   scripts/platform/copilot-auth.sh             use $COPILOT_GITHUB_TOKEN, else 'gh auth token --hostname github.com'
#   scripts/platform/copilot-auth.sh --remove    delete the stored credentials again
#
# The token goes into the github-token key of the Secret that only the copilot-cli sidecar reads;
# the agent containers never receive it. That is the Kubernetes pattern of the Copilot CLI server
# documentation (github/copilot-cli#5554): a Secret holds COPILOT_CONNECTION_TOKEN and
# COPILOT_GITHUB_TOKEN, and the container reads them through secretKeyRef. The token travels over
# stdin, so it never appears in a process listing or in this repository. The Pods that run the
# sidecar are restarted because env vars are read at container start.
#
# Accepted tokens: a fine-grained PAT with the "Copilot Requests" permission, or an OAuth token
# (such as the one 'gh auth token' prints). Classic ghp_ PATs are not supported by Copilot.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need kubectl base64 jq
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

ensure_agent_namespace
ensure_agent_secret

# Only the Deployments whose Pod runs the sidecar read the Secret.
restart_agents() {
  local deploys
  deploys="$(kube -n "$AGENT_NAMESPACE" get deployments -o json 2>/dev/null \
    | jq -r --arg sidecar "$SIDECAR_NAME" \
        '.items[] | select([.spec.template.spec.initContainers[]?.name] | index($sidecar)) | "deployment/\(.metadata.name)"' || true)"
  [ -n "$deploys" ] || return 0
  log "restarting the Pods that run the Copilot CLI sidecar so they pick up the change"
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
  token="$(gh auth token --hostname github.com 2>/dev/null || true)"
  source_name="'gh auth token --hostname github.com'"
fi
[ -n "$token" ] || die "no token found: set COPILOT_GITHUB_TOKEN (export COPILOT_GITHUB_TOKEN=\"\$(gh auth token --hostname github.com)\") or run 'gh auth login'"
case "$token" in
  ghp_*) die "classic personal access tokens (ghp_...) are not supported by Copilot; use a fine-grained PAT with the 'Copilot Requests' permission or an OAuth token" ;;
esac

printf '{"data":{"github-token":"%s"}}' "$(printf '%s' "$token" | base64 | tr -d '\n')" \
  | kube -n "$AGENT_NAMESPACE" patch secret "$AGENT_SECRET" --type=merge --patch-file=/dev/stdin >/dev/null
unset token
ok "stored the token from $source_name for the Copilot CLI sidecar (remove it with: make deauth)"
restart_agents
