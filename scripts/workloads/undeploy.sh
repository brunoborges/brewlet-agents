#!/usr/bin/env bash
# Removes a deployed agent or app (Deployment, Service, ServiceAccount) from the cluster.
#
#   scripts/workloads/undeploy.sh <agent-or-app>
#
# The shared Secret and the namespace stay; 'make deauth' removes GitHub credentials.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need kubectl

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent-or-app>"
namespace="$(workload_namespace "$agent")"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

kube -n "$namespace" delete deployment,service,serviceaccount "$agent" \
  --ignore-not-found --wait=true >/dev/null
ok "$agent removed from namespace $namespace"
