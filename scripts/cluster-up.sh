#!/usr/bin/env bash
# Creates (or reuses) the local platform:
#   1. a plain-HTTP OCI registry on localhost:$REGISTRY_PORT
#   2. a single-node kind cluster named $CLUSTER_NAME with a private kubeconfig
#   3. containerd on the node wired to that registry
#   4. Brewlet (operator, node provisioner, admission webhook) via Helm
# Safe to re-run. It never touches other kind clusters.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker kind kubectl helm curl

"$ROOT/scripts/install-brewlet.sh"
mkdir -p "$BUILD_DIR"

ARCH="$(host_arch)"
export DOCKER_DEFAULT_PLATFORM="linux/${ARCH}"
log "Docker architecture: linux/${ARCH}"

# --- 1. registry --------------------------------------------------------------
if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || true)" != "true" ]; then
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  log "starting registry $REGISTRY_NAME on 127.0.0.1:${REGISTRY_PORT}"
  docker run -d --restart=always --name "$REGISTRY_NAME" \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" "$REGISTRY_IMAGE" >/dev/null
else
  ok "registry $REGISTRY_NAME already running"
fi

# --- 2. kind cluster ----------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "kind cluster $CLUSTER_NAME already exists"
  kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG" >/dev/null
else
  log "creating kind cluster $CLUSTER_NAME"
  kind create cluster --name "$CLUSTER_NAME" --config "$ROOT/cluster/kind-config.yaml" \
    --kubeconfig "$KUBECONFIG" --wait 180s
fi
chmod 600 "$KUBECONFIG"

# --- 3. registry wiring -------------------------------------------------------
# The registry joins the kind network; containerd on each node maps
# localhost:$REGISTRY_PORT to it, so the same image reference works from the
# host (brewlet push) and from the node (kubelet and the Brewlet provisioner).
docker network connect kind "$REGISTRY_NAME" 2>/dev/null || true
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/${REGISTRY_HOST}"
  printf '[host."http://%s:5000"]\n' "$REGISTRY_NAME" \
    | docker exec -i "$node" tee "/etc/containerd/certs.d/${REGISTRY_HOST}/hosts.toml" >/dev/null
done
ok "containerd on the node maps ${REGISTRY_HOST} -> http://${REGISTRY_NAME}:5000"

# --- 4. Brewlet ---------------------------------------------------------------
if helm --kubeconfig "$KUBECONFIG" --kube-context "kind-${CLUSTER_NAME}" status brewlet -n brewlet >/dev/null 2>&1; then
  ok "Brewlet already installed"
else
  log "installing Brewlet ${BREWLET_VERSION}"
  helm --kubeconfig "$KUBECONFIG" --kube-context "kind-${CLUSTER_NAME}" install brewlet "$BREWLET_CHART" \
    --version "$BREWLET_VERSION" --namespace brewlet --create-namespace --wait --timeout 10m
fi

kube -n brewlet get pods
ok "cluster is ready. Use it with:  export KUBECONFIG=$KUBECONFIG"
