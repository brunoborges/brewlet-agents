#!/usr/bin/env bash
# Builds a derived runtime and pushes it to the local registry.
#
#   scripts/platform/runtime-build.sh <runtime-id>
#
# A derived runtime is a runtimes/<id>.env with BASE=<runtime id> and CONTEXT=<directory>: the approved
# image of BASE with whatever the Dockerfile in CONTEXT lays over it. runtimes/java-25-jlib is java-25
# plus the jlib-inspector agent. Its digest exists only once this script has built and pushed it, so
# nothing derived can be pinned in git: the digest is printed on stdout, recorded in
# build/runtimes/<id>/image, and scripts/platform/runtime-register.sh approves exactly that.
#
# The Dockerfile receives RUNTIME_IMAGE (the base image), FETCH_IMAGE (a pinned image to download
# files with) and every other ARG it declares from versions.env. The image tag is a hash of those
# inputs and of the Dockerfile, so a second run with the same inputs reuses the image already in the
# registry instead of producing another digest.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need docker curl openssl

[ "$#" -eq 1 ] || die "usage: $(basename "$0") <runtime-id>"
id="$1"
file="$ROOT/runtimes/$id.env"
[ -f "$file" ] || die "unknown runtime '$id' (no $file)"

base="$(env_value "$file" BASE)"
[ -n "$base" ] || die "runtime $id is not derived: $file has no BASE"
context="$ROOT/$(env_value "$file" CONTEXT)"
[ -f "$context/Dockerfile" ] || die "runtime $id: no Dockerfile in $context"
base_image="$(env_value "$ROOT/runtimes/$base.env" IMAGE)"
[ -n "$base_image" ] || die "runtime $id: its BASE $base has no IMAGE; derive from a plain runtime"
grep -q '^ARG RUNTIME_IMAGE$' "$context/Dockerfile" || die "$context/Dockerfile must declare ARG RUNTIME_IMAGE"

args=()
for name in $(sed -n 's/^ARG \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' "$context/Dockerfile"); do
  case "$name" in
    TARGETARCH|TARGETOS|TARGETPLATFORM|TARGETVARIANT) continue ;;
    RUNTIME_IMAGE) value="$base_image" ;;
    FETCH_IMAGE) value="$SIDECAR_FETCH_IMAGE" ;;
    *) value="$(printenv "$name")" || die "$context/Dockerfile declares ARG $name, which versions.env does not define" ;;
  esac
  args+=(--build-arg "$name=$value")
done

repo="runtimes/$id"
tag="$({ printf '%s\n' "${args[@]}"; cat "$context/Dockerfile"; } | openssl dgst -sha256 -r | cut -c1-12)"
digest="$(registry_digest "$repo" "$tag" || true)"
if [ -n "$digest" ]; then
  ok "runtime $id is already built: $REGISTRY_HOST/$repo:$tag"
else
  log "building $REGISTRY_HOST/$repo:$tag: $base plus $(basename "$context")"
  docker build --platform "linux/$(host_arch)" --provenance=false --sbom=false \
    "${args[@]}" -t "$REGISTRY_HOST/$repo:$tag" "$context" >&2
  docker push "$REGISTRY_HOST/$repo:$tag" >/dev/null
  digest="$(registry_digest "$repo" "$tag")"
  [ -n "$digest" ] || die "the registry returned no digest for $REGISTRY_HOST/$repo:$tag"
fi

mkdir -p "$BUILD_DIR/runtimes/$id"
printf '%s/%s@%s\n' "$REGISTRY_HOST" "$repo" "$digest" | tee "$BUILD_DIR/runtimes/$id/image"
