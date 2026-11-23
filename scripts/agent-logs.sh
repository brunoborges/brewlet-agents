#!/usr/bin/env bash
# Prints the recent logs of a deployed agent or app and, if its Pod has one, of the Copilot CLI
# sidecar.
#
#   scripts/agent-logs.sh <agent-or-app> [lines]     lines of the main container; default 40
#
# 'make logs AGENT=<name>' (or APP=<name>) calls this script.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl

name="${1:-}"
[ -n "$name" ] || die "usage: $(basename "$0") <agent-or-app> [lines]"
lines="${2:-40}"
agent_dir "$name" >/dev/null
namespace="$(workload_namespace "$name")"
container="$(workload_container "$name")"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"
kube -n "$namespace" get deployment "$name" >/dev/null 2>&1 \
  || die "$name is not deployed in namespace $namespace: run 'make agent AGENT=$name'"

log "$name: container $container, last $lines lines"
kube -n "$namespace" logs "deployment/$name" -c "$container" --tail="$lines"
if workload_has_sidecar "$name"; then
  log "$name: container $SIDECAR_NAME (the sidecar), last 10 lines"
  kube -n "$namespace" logs "deployment/$name" -c "$SIDECAR_NAME" --tail=10
fi
