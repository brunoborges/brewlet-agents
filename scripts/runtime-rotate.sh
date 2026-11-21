#!/usr/bin/env bash
# Rolls a runtime to a new image generation without touching any agent artifact.
#
#   scripts/runtime-rotate.sh <runtime-id> <image>
#
# <image> is a tag or a digest. The node installs the new generation next to the old one. Running
# Pods keep the generation they started with and new Pods get the new one. Brewlet's operator
# replaces the Pods of Deployments that opted in with brewlet.sh/restart-on-rotation when the Helm
# chart enables operator.rotationRestarts (scripts/cluster-up.sh does). Restart anything else
# yourself:
#   kubectl -n agents rollout restart deployment
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl brewlet jq

[ "$#" -eq 2 ] || die "usage: $(basename "$0") <runtime-id> <image>"
id="$1" image="$2"

flags=(--yes)
case "$image" in
  localhost:*|127.0.0.1:*) flags+=(--insecure) ;;   # the local registry speaks plain HTTP
esac

previous="$(kube get runtimeimage "$id" -o jsonpath='{.status.generation}')"
log "rotating runtime $id (generation ${previous:-?}) to $image"

# The operator keeps updating the RuntimeImage's status, most of all while it settles a rotation. The
# CLI reads the object and then patches it, so now and then the patch loses that race with "the object
# has been modified". Nothing was written in that case, so asking again is safe; any other error is final.
rotate() {
  local attempt out
  for attempt in 1 2 3 4 5; do
    if out="$(brewlet k8s runtime rotate "$id" --image "$image" "${flags[@]}" 2>&1)"; then
      printf '%s\n' "$out"
      return 0
    fi
    case "$out" in
      *"the object has been modified"*)
        warn "the RuntimeImage changed while the CLI was patching it (attempt $attempt of 5); asking again"
        sleep 2 ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$out" >&2
  return 1
}
rotate || die "could not rotate runtime $id to $image"

# Rotation is done when the node runs a newer generation and RotationComplete observes the
# current spec. Waiting on the generation alone would race the old, still-true condition.
deadline=$((SECONDS + 900))
until kube get runtimeimage "$id" -o json | jq -e --argjson previous "${previous:-0}" '
      .metadata.generation as $spec
      | (.status.generation // 0) > $previous
        and ([.status.conditions[]? | select(.type == "RotationComplete" and .status == "True" and .observedGeneration == $spec)] | length == 1)
    ' >/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || die "runtime $id did not finish rotating within 15 minutes: brewlet k8s runtime status $id"
  sleep 3
done

brewlet k8s runtime status "$id"
ok "runtime $id is at generation $(kube get runtimeimage "$id" -o jsonpath='{.status.generation}'); new Pods use it"
