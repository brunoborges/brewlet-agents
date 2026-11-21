#!/usr/bin/env bash
# Removes a deployed agent (Deployment, Service, ServiceAccount) from the cluster.
#
#   scripts/agent-undeploy.sh <agent>
#
# The shared Secret and the namespace stay; 'make deauth' removes GitHub credentials.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent>"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

kube -n "$AGENT_NAMESPACE" delete deployment,service,serviceaccount "$agent" \
  --ignore-not-found --wait=true >/dev/null
ok "$agent removed from namespace $AGENT_NAMESPACE"
