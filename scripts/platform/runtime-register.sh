#!/usr/bin/env bash
# Approves runtimes in the cluster: the Ops-owned half of Brewlet.
#
#   scripts/platform/runtime-register.sh               every runtimes/*.env
#   scripts/platform/runtime-register.sh java-25 ...   only those
#
# Each runtimes/<id>.env pins one plain base image by digest, or names a BASE runtime to derive from
# (scripts/platform/runtime-build.sh builds that image and pushes it to the local registry first). Registering
# writes a cluster-scoped RuntimeImage and offers it through the "local" NodeProfile, which makes the
# Brewlet operator install it on the node. Safe to re-run.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need kubectl brewlet docker

PROFILE=local
ARCH="$(host_arch)"
STARTUP_TAINT='startup-taint.cluster-autoscaler.kubernetes.io/brewlet=provisioning:NoSchedule'

kube get nodes >/dev/null 2>&1 || die "no cluster reachable; run 'make cluster' first"

profile_offers() {
  kube get nodeprofile "$PROFILE" -o jsonpath='{.spec.runtimeImages[*].id}' 2>/dev/null \
    | tr ' ' '\n' | grep -qx "$1"
}

register() {
  local id="$1" file="$ROOT/runtimes/$1.env"
  [ -f "$file" ] || die "unknown runtime '$id' (no $file)"
  local base uid gid ecosystem abi mounts description
  base="$(env_value "$file" BASE)"
  uid="$(env_value "$file" RUNTIME_UID)"
  gid="$(env_value "$file" RUNTIME_GID)"
  ecosystem="$(env_value "$file" ECOSYSTEM)"
  abi="$(env_value "$file" ABI)"
  mounts="$(env_value "$file" MOUNT_PATHS)"
  description="$(env_value "$file" DESCRIPTION)"

  if kube get runtimeimage "$id" >/dev/null 2>&1; then
    ok "runtime $id is already approved (scripts/platform/runtime-rotate.sh changes its image)"
  else
    local image
    if [ -n "$base" ]; then
      image="$("$ROOT/scripts/platform/runtime-build.sh" "$id")" || die "could not build runtime $id"
    else
      image="$(env_value "$file" IMAGE)"
    fi
    log "approving runtime $id: $description"
    local args=(k8s runtime add "$id" --image "$image" --uid "$uid" --gid "$gid"
                --platform "linux/$ARCH" --description "$description")
    case "$image" in
      localhost:*|127.0.0.1:*) args+=(--insecure) ;;   # the local registry speaks plain HTTP
    esac
    [ -z "$ecosystem" ] || args+=(--ecosystem "$ecosystem")
    [ -z "$abi" ] || args+=(--abi "$abi")
    local path
    for path in $mounts; do args+=(--volume-mount-path "$path"); done
    # The admission webhook can take a moment to answer after the Helm install.
    retry 12 brewlet "${args[@]}" || die "could not approve runtime $id"
  fi

  if ! kube get nodeprofile "$PROFILE" >/dev/null 2>&1; then
    log "creating NodeProfile $PROFILE with $id"
    retry 12 brewlet k8s profile create "$PROFILE" --all-nodes --include-control-plane \
      --toleration "$STARTUP_TAINT" --runtime "$id" || die "could not create NodeProfile $PROFILE"
  elif ! profile_offers "$id"; then
    log "offering $id through NodeProfile $PROFILE"
    retry 12 brewlet k8s profile add-runtime "$PROFILE" "$id" || die "could not add $id to $PROFILE"
  fi
}

if [ "$#" -gt 0 ]; then
  ids=("$@")
else
  ids=()
  for f in "$ROOT"/runtimes/*.env; do ids+=("$(basename "$f" .env)"); done
fi

for id in "${ids[@]}"; do register "$id"; done

# The node worker pulls each runtime image from its registry, so the first install takes as
# long as the download does. Until it finishes the worker pod reports "lstat /run/brewlet:
# no such file or directory" in its readiness probe; that is expected, not a failure.
log "waiting for the node to install the runtimes (the first pull of a ~200 MB image can take 10+ minutes on a slow link)"
kube wait --for=condition=Ready "nodeprofile/$PROFILE" --timeout=40m
for id in "${ids[@]}"; do brewlet k8s runtime status "$id"; done
ok "runtimes ready: ${ids[*]}"
