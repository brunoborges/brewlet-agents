#!/usr/bin/env bash
# Shows what a published agent artifact is made of: its layers, their sizes and the digest that
# deployments pin. The manifest is read back from the registry, so this is what was really pushed.
#
#   scripts/workloads/layers.sh <agent>            the layers and their compressed sizes
#   scripts/workloads/layers.sh <agent> --bytes    only the compressed size of the whole artifact, in bytes
#
# The first layers are the entries of the agent's "layers" file, in order; Brewlet adds the
# launch.json as the last one. Sizes are the compressed sizes a node downloads.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need curl jq awk

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent> [--bytes]"
dir="$(agent_dir "$agent")"
pinned_file="$(artifact_out "$agent")/pinned"
[ -f "$pinned_file" ] || die "$agent is not published: run 'make publish AGENT=$agent' first"

pinned="$(cat "$pinned_file")"
digest="${pinned##*@}"
repo="${pinned%@*}"
repo="${repo#"$REGISTRY_HOST"/}"
manifest="$(curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "http://$REGISTRY_HOST/v2/$repo/manifests/$digest")" \
  || die "could not read $repo@$digest from the registry at $REGISTRY_HOST"

if [ "${2:-}" = "--bytes" ]; then
  jq '[.layers[].size] | add' <<<"$manifest"
  exit 0
fi

human() { # BYTES
  awk -v n="$1" 'BEGIN {
    split("B KiB MiB GiB", unit, " "); i = 1
    while (n >= 1024 && i < 4) { n /= 1024; i++ }
    fmt = (i == 1) ? "%d %s" : "%.1f %s"
    printf fmt, n, unit[i]
  }'
}

labels=()
if [ -f "$dir/layers" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    labels+=("${line%%:*} -> ${line#*:}")
  done < "$dir/layers"
else
  labels+=("app -> /app")
fi
labels+=("launch.json")

log "$agent: $repo@${digest:0:19}"
printf '  %-6s %-10s %-14s %s\n' LAYER SIZE DIGEST CONTENT
n=0
total=0
while read -r size layer_digest; do
  n=$((n + 1))
  total=$((total + size))
  printf '  %-6s %-10s %-14s %s\n' "$n" "$(human "$size")" "${layer_digest:0:14}" "${labels[$((n - 1))]:-}"
done < <(jq -r '.layers[] | "\(.size) \(.digest)"' <<<"$manifest")
printf '  %-6s %s\n' total "$(human "$total")"
