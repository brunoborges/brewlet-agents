#!/usr/bin/env bash
# Prints an agent's manifest (agents/<agent>/deployment.yaml) on stdout with its two images pinned.
#
#   scripts/agent-pin.sh <agent> <artifact-ref> <sidecar-ref>
#
# The manifest is complete and applied as written. The one thing that changes is the pair of `image:`
# lines: the file names the tags that scripts/agent-build.sh and scripts/sidecar-build.sh push, and
# Brewlet runs only digest-pinned application images, so the digests go in here. A tag that is not
# the expected one is an error rather than a silent no-op.
#
# scripts/agent-deploy.sh applies the result. scripts/check.sh pins every agent with placeholder
# digests, so a drifting manifest fails in CI without a cluster.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ "$#" -eq 3 ] || die "usage: $(basename "$0") <agent> <artifact-ref> <sidecar-ref>"
agent="$1" artifact="$2" sidecar="$3"
manifest="$(agent_dir "$agent")/deployment.yaml"
[ -f "$manifest" ] || die "$agent: deployment.yaml is missing"

artifact_tag="$REGISTRY_HOST/agents/$agent:dev"
sidecar_tag="$(sidecar_ref)"

pinned="$(awk -v artifact_tag="$artifact_tag" -v artifact="$artifact" -v sidecar_tag="$sidecar_tag" -v sidecar="$sidecar" '
  $1 == "image:" && $2 == artifact_tag { sub(/image:.*/, "image: " artifact); artifacts++ }
  $1 == "image:" && $2 == sidecar_tag  { sub(/image:.*/, "image: " sidecar); sidecars++ }
  { print }
  END { exit (artifacts == 1 && sidecars == 1) ? 0 : 1 }
' "$manifest")" || die "$agent: deployment.yaml must have exactly one 'image: $artifact_tag' and one 'image: $sidecar_tag' line"
printf '%s\n' "$pinned"
