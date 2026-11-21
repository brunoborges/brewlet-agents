#!/usr/bin/env bash
# Rolls a runtime to a new image generation without touching any agent artifact.
#
#   scripts/runtime-rotate.sh <runtime-id> <image>
#
# <image> is a tag or digest. Running Pods keep the generation they started with;
# restart them to pick up the new one:
#   kubectl -n agents rollout restart deployment
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl brewlet

[ "$#" -eq 2 ] || die "usage: $(basename "$0") <runtime-id> <image>"
id="$1" image="$2"

flags=(--yes)
case "$image" in
  localhost:*|127.0.0.1:*) flags+=(--insecure) ;;   # the local registry speaks plain HTTP
esac

log "rotating runtime $id to $image"
brewlet k8s runtime rotate "$id" --image "$image" "${flags[@]}"
kube wait --for=condition=Ready nodeprofile/local --timeout=10m
brewlet k8s runtime status "$id"
ok "runtime $id rotated; restart the agents to use it: kubectl -n ${AGENT_NAMESPACE} rollout restart deployment"
