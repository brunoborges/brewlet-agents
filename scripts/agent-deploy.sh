#!/usr/bin/env bash
# Deploys a published agent to the kind cluster: applies agents/<agent>/deployment.yaml (one Pod
# with the agent container on the Ops-owned runtime and the Copilot CLI sidecar), with its two
# images pinned to the digests that were just published.
#
#   scripts/agent-deploy.sh <agent>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker kubectl curl openssl base64

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent>"
agent_dir "$agent" >/dev/null
out="$BUILD_DIR/agents/$agent"
[ -f "$out/pinned" ] || die "$agent is not published: run 'make publish AGENT=$agent' first"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

artifact="$(cat "$out/pinned")"
sidecar_digest="$(registry_digest "$SIDECAR_NAME" "$COPILOT_CLI_VERSION")"
[ -n "$sidecar_digest" ] || die "sidecar image missing from the registry: run 'make sidecar' first"

ensure_agent_namespace
ensure_agent_secret

"$ROOT/scripts/agent-pin.sh" "$agent" "$artifact" "$REGISTRY_HOST/$SIDECAR_NAME@$sidecar_digest" > "$out/deployment.yaml"

log "deploying $agent to namespace $AGENT_NAMESPACE"
kube apply -f "$out/deployment.yaml" >/dev/null

if ! kube -n "$AGENT_NAMESPACE" rollout status "deployment/$agent" --timeout=5m; then
  warn "$agent did not become ready; recent Pod events and logs:"
  kube -n "$AGENT_NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -n 15 >&2 || true
  kube -n "$AGENT_NAMESPACE" logs "deployment/$agent" -c agent --tail=40 >&2 || true
  kube -n "$AGENT_NAMESPACE" logs "deployment/$agent" -c copilot-cli --tail=20 >&2 || true
  die "$agent failed to roll out"
fi
ok "$agent is running: $artifact"
