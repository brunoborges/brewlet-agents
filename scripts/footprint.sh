#!/usr/bin/env bash
# What the deployed agents and apps cost: the size of each artifact and the memory each container
# uses right now, measured by the container runtime on the kind node (crictl stats, "working set").
#
#   scripts/footprint.sh [agent-or-app ...]     default: every agent and app that is deployed
#
# The numbers are a snapshot. Run it on a fresh Pod for the idle footprint, and again after a few
# requests for the warm one.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker kubectl jq awk

[ -f "$KUBECONFIG" ] || die "no cluster: run 'make up' first"
node="${CLUSTER_NAME}-control-plane"

workloads="$*"
if [ -z "$workloads" ]; then
  for dir in "$ROOT"/agents/*/ "$ROOT"/apps/*/; do
    dir="${dir%/}"
    [ -f "$(workload_env "$dir")" ] || continue
    name="$(basename "$dir")"
    if kube -n "$(workload_namespace "$name")" get deployment "$name" >/dev/null 2>&1; then
      workloads="$workloads $name"
    fi
  done
fi
[ -n "$workloads" ] || die "nothing is deployed: run 'make agent AGENT=java-spring' first"

stats="$(docker exec "$node" crictl stats -o json)" || die "could not read container stats from $node"

# working_set POD CONTAINER: MiB, or "-" when the container is not running.
working_set() {
  jq -r --arg pod "$1" --arg c "$2" '
    [.stats[]
     | select(.attributes.labels["io.kubernetes.pod.name"] == $pod and .attributes.labels["io.kubernetes.container.name"] == $c)
     | .memory.workingSetBytes.value // empty | tonumber][0] // empty' <<<"$stats" \
    | awk '{ printf "%.0f", $1 / 1048576 } END { if (NR == 0) printf "-" }'
}

printf '%-22s %-14s %12s %9s %12s\n' NAME RUNTIME "ARTIFACT MiB" "APP MiB" "SIDECAR MiB"
for name in $workloads; do
  dir="$(agent_dir "$name")"
  runtime="$(env_value "$(workload_env "$dir")" RUNTIME)"
  pod="$(kube -n "$(workload_namespace "$name")" get pods -l "app.kubernetes.io/name=$name" -o json \
    | jq -r '[.items[] | select(.status.phase == "Running")][0].metadata.name // empty')"
  artifact="-"
  if [ -f "$(artifact_out "$name")/pinned" ]; then
    artifact="$("$ROOT/scripts/agent-layers.sh" "$name" --bytes | awk '{ printf "%.1f", $1 / 1048576 }')"
  fi
  if [ -z "$pod" ]; then
    printf '%-22s %-14s %12s %9s %12s\n' "$name" "$runtime" "$artifact" "-" "-"
    continue
  fi
  sidecar="-"
  if workload_has_sidecar "$name"; then sidecar="$(working_set "$pod" "$SIDECAR_NAME")"; fi
  printf '%-22s %-14s %12s %9s %12s\n' "$name" "$runtime" "$artifact" \
    "$(working_set "$pod" "$(workload_container "$name")")" "$sidecar"
done
