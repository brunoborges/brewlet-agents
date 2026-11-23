#!/usr/bin/env bash
# Prints the deployment.yaml from a workload's directory with its image pinned.
#
#   scripts/workloads/pin.sh <agent-or-app> <artifact-ref>
#
# The manifest is complete and applied as written. The one thing that changes is the workload's
# `image:` line: the file names the tag that make publish pushes, and Brewlet runs only
# digest-pinned application images, so the digest goes in here. The Copilot CLI sidecar, when the
# workload has one, already names COPILOT_CLI_IMAGE from versions.env and is left as written. A line
# that is not the expected one is an error rather than a silent no-op.
#
# scripts/workloads/deploy.sh applies the result. scripts/checks/repository.sh pins every workload with a
# placeholder digest, so a drifting manifest fails in CI without a cluster.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

[ "$#" -eq 2 ] || die "usage: $(basename "$0") <agent-or-app> <artifact-ref>"
agent="$1" artifact="$2"
manifest="$(agent_dir "$agent")/deployment.yaml"
[ -f "$manifest" ] || die "$agent: deployment.yaml is missing"

artifact_tag="$REGISTRY_HOST/$(artifact_repo "$agent"):dev"
if workload_has_sidecar "$agent"; then
  expected_sidecars=1
  expectation="exactly one 'image: $artifact_tag' and one 'image: $COPILOT_CLI_IMAGE' line"
else
  expected_sidecars=0
  expectation="exactly one 'image: $artifact_tag' line and no sidecar image"
fi

pinned="$(awk -v artifact_tag="$artifact_tag" -v artifact="$artifact" -v sidecar="$COPILOT_CLI_IMAGE" -v expected="$expected_sidecars" '
  $1 == "image:" && $2 == artifact_tag { sub(/image:.*/, "image: " artifact); artifacts++ }
  $1 == "image:" && $2 == sidecar      { sidecars++ }
  { print }
  END { exit (artifacts == 1 && sidecars == expected) ? 0 : 1 }
' "$manifest")" || die "$agent: deployment.yaml must have $expectation"
printf '%s\n' "$pinned"
