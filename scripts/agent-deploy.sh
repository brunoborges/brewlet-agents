#!/usr/bin/env bash
# Deploys a published agent to the kind cluster: one Pod with the agent container (running on
# the Ops-owned runtime) and the Copilot CLI sidecar.
#
#   scripts/agent-deploy.sh <agent>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker kubectl curl openssl base64

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent>"
dir="$(agent_dir "$agent")"
out="$BUILD_DIR/agents/$agent"
[ -f "$out/pinned" ] || die "$agent is not published: run 'make publish AGENT=$agent' first"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

artifact="$(cat "$out/pinned")"
runtime="$(env_value "$dir/agent.env" RUNTIME)"
language="$(env_value "$dir/agent.env" LANGUAGE)"
port="$(env_value "$dir/agent.env" PORT)"
cpu_request="$(env_value "$dir/agent.env" CPU_REQUEST)"
memory_request="$(env_value "$dir/agent.env" MEMORY_REQUEST)"
memory_limit="$(env_value "$dir/agent.env" MEMORY_LIMIT)"

sidecar_digest="$(registry_digest "$SIDECAR_NAME" "$COPILOT_CLI_VERSION")"
[ -n "$sidecar_digest" ] || die "sidecar image missing from the registry: run 'make sidecar' first"

ensure_agent_namespace
ensure_agent_secret

sed \
  -e "s|@@AGENT@@|$agent|g" \
  -e "s|@@NAMESPACE@@|$AGENT_NAMESPACE|g" \
  -e "s|@@SECRET@@|$AGENT_SECRET|g" \
  -e "s|@@LANGUAGE@@|$language|g" \
  -e "s|@@RUNTIME@@|$runtime|g" \
  -e "s|@@ARCH@@|$(host_arch)|g" \
  -e "s|@@ARTIFACT@@|$artifact|g" \
  -e "s|@@PORT@@|${port:-8080}|g" \
  -e "s|@@SIDECAR@@|$REGISTRY_HOST/$SIDECAR_NAME@$sidecar_digest|g" \
  -e "s|@@SIDECAR_PORT@@|$SIDECAR_PORT|g" \
  -e "s|@@SIDECAR_MEMORY_REQUEST@@|${SIDECAR_MEMORY_REQUEST:-128Mi}|g" \
  -e "s|@@SIDECAR_MEMORY_LIMIT@@|${SIDECAR_MEMORY_LIMIT:-512Mi}|g" \
  -e "s|@@CPU_REQUEST@@|${cpu_request:-100m}|g" \
  -e "s|@@MEMORY_REQUEST@@|${memory_request:-192Mi}|g" \
  -e "s|@@MEMORY_LIMIT@@|${memory_limit:-512Mi}|g" \
  "$ROOT/deploy/agent.yaml.tmpl" > "$out/agent.yaml"

log "deploying $agent to namespace $AGENT_NAMESPACE"
kube apply -f "$out/agent.yaml" >/dev/null

if ! kube -n "$AGENT_NAMESPACE" rollout status "deployment/$agent" --timeout=5m; then
  warn "$agent did not become ready; recent Pod events and logs:"
  kube -n "$AGENT_NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -n 15 >&2 || true
  kube -n "$AGENT_NAMESPACE" logs "deployment/$agent" -c agent --tail=40 >&2 || true
  kube -n "$AGENT_NAMESPACE" logs "deployment/$agent" -c copilot-cli --tail=20 >&2 || true
  die "$agent failed to roll out"
fi
ok "$agent is running: $artifact"
