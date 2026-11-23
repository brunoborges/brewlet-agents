#!/usr/bin/env bash
# Prints a workload's manifest (<agents|apps>/<name>/deployment.yaml) on stdout with its images pinned.
#
#   scripts/agent-pin.sh <agent> <artifact-ref> <sidecar-ref>
#   scripts/agent-pin.sh <app> <artifact-ref> [<sidecar-ref>]     the sidecar only if the app has one
#
# The manifest is complete and applied as written. The one thing that changes is the `image:` lines:
# the file names the tags that scripts/agent-build.sh and scripts/sidecar-build.sh push, and
# Brewlet runs only digest-pinned application images, so the digests go in here. A tag that is not
# the expected one is an error rather than a silent no-op.
#
# scripts/agent-deploy.sh applies the result. scripts/check.sh pins every workload with placeholder
# digests, so a drifting manifest fails in CI without a cluster.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || die "usage: $(basename "$0") <agent-or-app> <artifact-ref> [<sidecar-ref>]"
agent="$1" artifact="$2" sidecar="${3:-}"
manifest="$(agent_dir "$agent")/deployment.yaml"
[ -f "$manifest" ] || die "$agent: deployment.yaml is missing"

artifact_tag="$REGISTRY_HOST/$(artifact_repo "$agent"):dev"
sidecar_tag="$(sidecar_ref)"
if workload_has_sidecar "$agent"; then
  [ -n "$sidecar" ] || die "$agent runs next to the Copilot CLI sidecar: pass its image reference"
  expected_sidecars=1
  expectation="exactly one 'image: $artifact_tag' and one 'image: $sidecar_tag' line"
else
  expected_sidecars=0
  expectation="exactly one 'image: $artifact_tag' line and no sidecar image"
fi

pinned="$(awk -v artifact_tag="$artifact_tag" -v artifact="$artifact" -v sidecar_tag="$sidecar_tag" -v sidecar="$sidecar" -v expected="$expected_sidecars" '
  $1 == "image:" && $2 == artifact_tag { sub(/image:.*/, "image: " artifact); artifacts++ }
  $1 == "image:" && $2 == sidecar_tag  { sub(/image:.*/, "image: " sidecar); sidecars++ }
  { print }
  END { exit (artifacts == 1 && sidecars == expected) ? 0 : 1 }
' "$manifest")" || die "$agent: deployment.yaml must have $expectation"
printf '%s\n' "$pinned"
