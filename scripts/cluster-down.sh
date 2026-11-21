#!/usr/bin/env bash
# Tears down everything cluster-up.sh created, in the order Brewlet documents:
# workloads, then the NodeProfile (so the provisioner can clean the node), then
# the control plane, then the cluster and registry. Only touches this project's
# cluster and registry.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker kind kubectl helm

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" && [ -f "$KUBECONFIG" ]; then
  log "removing workloads"
  kube delete deployment --all --all-namespaces --selector app.kubernetes.io/part-of=brewlet-agents --ignore-not-found --timeout=2m || true
  log "removing NodeProfile (lets the provisioner clean the node)"
  kube delete nodeprofile --all --ignore-not-found --timeout=10m || true
  kube delete runtimeimage --all --ignore-not-found --timeout=5m || true
  helm --kubeconfig "$KUBECONFIG" --kube-context "kind-${CLUSTER_NAME}" uninstall brewlet -n brewlet --wait --timeout 5m || true
  log "deleting kind cluster $CLUSTER_NAME"
  kind delete cluster --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" || true
else
  ok "kind cluster $CLUSTER_NAME not present"
fi

if docker inspect "$REGISTRY_NAME" >/dev/null 2>&1; then
  log "removing registry $REGISTRY_NAME"
  docker rm -f "$REGISTRY_NAME" >/dev/null
fi
rm -f "$KUBECONFIG"
ok "teardown complete"
