#!/usr/bin/env bash
# Builds the Copilot CLI sidecar image and pushes it to the local registry.
#
#   scripts/platform/sidecar-build.sh            build for the Docker VM's architecture
#
# The image is an ordinary OCI image. Brewlet only manages the container that
# selects a runtime; the sidecar is just another container in the Pod.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need docker curl

ARCH="$(host_arch)"
REF="$(sidecar_ref)"

log "building $REF (linux/${ARCH}, Copilot CLI ${COPILOT_CLI_VERSION})"
docker build \
  --platform "linux/${ARCH}" --provenance=false --sbom=false \
  --build-arg "FETCH_IMAGE=${SIDECAR_FETCH_IMAGE}" \
  --build-arg "SIDECAR_BASE_IMAGE=${SIDECAR_BASE_IMAGE}" \
  --build-arg "COPILOT_CLI_VERSION=${COPILOT_CLI_VERSION}" \
  --build-arg "COPILOT_CLI_SHA256_LINUX_ARM64=${COPILOT_CLI_SHA256_LINUX_ARM64}" \
  --build-arg "COPILOT_CLI_SHA256_LINUX_X64=${COPILOT_CLI_SHA256_LINUX_X64}" \
  -t "$REF" "$ROOT/sidecars/copilot-cli"

log "pushing $REF"
docker push "$REF" >/dev/null
ok "sidecar $REF  ($(registry_digest "$SIDECAR_NAME" "$COPILOT_CLI_VERSION"))"
