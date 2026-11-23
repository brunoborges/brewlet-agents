#!/usr/bin/env bash
# Deploys a published agent or app to the kind cluster: applies <agents|apps>/<name>/deployment.yaml
# with its images pinned to the digests that were just published. An agent is one Pod with the agent
# container on the Ops-owned runtime and the Copilot CLI sidecar; an app has the sidecar only if its
# app.env says SIDECAR=copilot-cli, and may run in another namespace (NAMESPACE=...).
#
#   scripts/workloads/deploy.sh <agent-or-app>
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need docker kubectl curl openssl base64

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent-or-app>"
agent_dir "$agent" >/dev/null
out="$(artifact_out "$agent")"
namespace="$(workload_namespace "$agent")"
[ -f "$out/pinned" ] || die "$agent is not published: run 'make publish AGENT=$agent' first"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

artifact="$(cat "$out/pinned")"
sidecar_args=()
if workload_has_sidecar "$agent"; then
  sidecar_digest="$(registry_digest "$SIDECAR_NAME" "$COPILOT_CLI_VERSION")"
  [ -n "$sidecar_digest" ] || die "sidecar image missing from the registry: run 'make sidecar' first"
  sidecar_args=("$REGISTRY_HOST/$SIDECAR_NAME@$sidecar_digest")
  # The sidecar reads its tokens from the Secret in the agents' namespace.
  [ "$namespace" = "$AGENT_NAMESPACE" ] || die "$agent: an app with the Copilot CLI sidecar has to run in namespace $AGENT_NAMESPACE, where Secret $AGENT_SECRET lives"
  ensure_agent_namespace
  ensure_agent_secret
else
  ensure_namespace "$namespace"
fi

"$ROOT/scripts/workloads/pin.sh" "$agent" "$artifact" ${sidecar_args[@]+"${sidecar_args[@]}"} > "$out/deployment.yaml"

log "deploying $agent to namespace $namespace"
kube apply -f "$out/deployment.yaml" >/dev/null

if ! kube -n "$namespace" rollout status "deployment/$agent" --timeout=5m; then
  warn "$agent did not become ready; recent Pod events and logs:"
  kube -n "$namespace" get events --sort-by=.lastTimestamp 2>&1 | tail -n 15 >&2 || true
  kube -n "$namespace" logs "deployment/$agent" --all-containers --prefix --tail=40 >&2 || true
  die "$agent failed to roll out"
fi
ok "$agent is running in namespace $namespace: $artifact"
