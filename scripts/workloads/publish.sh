#!/usr/bin/env bash
# Pushes a built agent or app artifact to the local registry and records the digest deployments pin.
#
#   scripts/workloads/publish.sh <agent-or-app>
#
# Brewlet only runs digest-pinned application images, so the digest (not the tag) is what matters.
# The pushed digest equals the built digest: the registry never rewrites a byte.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need docker jq

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent-or-app>"
agent_dir "$agent" >/dev/null
out="$(artifact_out "$agent")"
[ -f "$out/ref" ] || die "$agent is not built: run scripts/workloads/build.sh $agent"

ref="$(cat "$out/ref")"
arch="$(host_arch)"

brewlet push "$ref" --store "$out/store" --insecure -push-result "$out/push-result.json" >/dev/null
digest="$(jq -r '.digest // empty' "$out/push-result.json")"
case "$digest" in sha256:*) ;; *) die "could not read the pushed digest from $out/push-result.json" ;; esac

pinned="${ref%:*}@$digest"
brewlet verify "$pinned" --platform "linux/$arch" --insecure >/dev/null
echo "$pinned" > "$out/pinned"
ok "$agent published and verified: $pinned"
