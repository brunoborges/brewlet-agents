#!/usr/bin/env bash
# What the deployed agents cost: the size of each artifact and the memory each container uses right
# now, measured by the container runtime on the kind node (crictl stats, "working set").
#
#   scripts/footprint.sh [agent ...]     default: every agent that is deployed
#
# The numbers are a snapshot. Run it on a fresh Pod for the idle footprint, and again after a few
# 'make ask' calls for the warm one.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker kubectl jq awk

[ -f "$KUBECONFIG" ] || die "no cluster: run 'make up' first"
node="${CLUSTER_NAME}-control-plane"

agents="$*"
if [ -z "$agents" ]; then
  agents="$(kube -n "$AGENT_NAMESPACE" get deployments -o json | jq -r '.items[].metadata.name' | sort)"
fi
[ -n "$agents" ] || die "no agent is deployed: run 'make agent AGENT=java-spring' first"

stats="$(docker exec "$node" crictl stats -o json)" || die "could not read container stats from $node"

# working_set POD CONTAINER: MiB, or "-" when the container is not running.
working_set() {
  jq -r --arg pod "$1" --arg c "$2" '
    [.stats[]
     | select(.attributes.labels["io.kubernetes.pod.name"] == $pod and .attributes.labels["io.kubernetes.container.name"] == $c)
     | .memory.workingSetBytes.value // empty | tonumber][0] // empty' <<<"$stats" \
    | awk '{ printf "%.0f", $1 / 1048576 } END { if (NR == 0) printf "-" }'
}

printf '%-16s %-12s %12s %10s %12s\n' AGENT RUNTIME "ARTIFACT MiB" "AGENT MiB" "SIDECAR MiB"
for agent in $agents; do
  dir="$(agent_dir "$agent")"
  runtime="$(env_value "$dir/agent.env" RUNTIME)"
  pod="$(kube -n "$AGENT_NAMESPACE" get pods -l "app.kubernetes.io/name=$agent" -o json \
    | jq -r '[.items[] | select(.status.phase == "Running")][0].metadata.name // empty')"
  artifact="-"
  if [ -f "$BUILD_DIR/agents/$agent/pinned" ]; then
    artifact="$("$ROOT/scripts/agent-layers.sh" "$agent" --bytes | awk '{ printf "%.1f", $1 / 1048576 }')"
  fi
  if [ -z "$pod" ]; then
    printf '%-16s %-12s %12s %10s %12s\n' "$agent" "$runtime" "$artifact" "-" "-"
    continue
  fi
  printf '%-16s %-12s %12s %10s %12s\n' "$agent" "$runtime" "$artifact" \
    "$(working_set "$pod" agent)" "$(working_set "$pod" "$SIDECAR_NAME")"
done
