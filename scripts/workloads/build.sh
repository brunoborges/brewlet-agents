#!/usr/bin/env bash
# Builds one agent or app into a Brewlet application artifact: its code, its dependencies and its
# launch.json, and nothing else. The language runtime and the Copilot CLI are not in it.
#
#   scripts/workloads/build.sh <agent-or-app>
#
# The artifact lands in a local Brewlet store (build/<agents|apps>/<name>/store); scripts/workloads/publish.sh
# pushes it. Per-workload inputs live in agents/<name>/ or apps/<name>/: agent.env or app.env,
# build.sh, launch.json and an optional "layers" file.
#
# Agents are built against the Copilot SDK integrations of their language. An app does so only when
# its app.env says INTEGRATIONS=<language>.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need docker

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent-or-app>"
dir="$(agent_dir "$agent")"
envfile="$(workload_env "$dir")"
language="$(env_value "$envfile" LANGUAGE)"
runtime="$(env_value "$envfile" RUNTIME)"
[ -n "$language" ] && [ -n "$runtime" ] || die "$agent: $(basename "$envfile") needs LANGUAGE and RUNTIME"
[ -f "$dir/launch.json" ] || die "$agent: missing launch.json"
grep -q "\"$runtime\"" "$dir/launch.json" \
  || die "$agent: launch.json runtimeImages must list the runtime id \"$runtime\" from $(basename "$envfile")"
[ -x "$ROOT/.bin/brewlet" ] || die "Brewlet CLI missing: run 'make cluster' (scripts/platform/install-brewlet.sh) first"

arch="$(host_arch)"
if [ "$(workload_kind "$agent")" = agents ]; then integrations="$language"; else integrations="$(env_value "$envfile" INTEGRATIONS)"; fi
if [ -n "$integrations" ]; then
  "$ROOT/scripts/integrations/build.sh" "$integrations"
  export INTEGRATIONS_OUT="$BUILD_DIR/integrations/$integrations"
fi

out="$(artifact_out "$agent")"
APP_DIR="$out/app"
rm -rf "$out"
mkdir -p "$APP_DIR"
export APP_DIR ARCH="$arch"

log "building $agent ($language, runtime $runtime, linux/$arch)"
bash "$dir/build.sh"

# Brewlet refuses unsafe files instead of sanitizing them: regular files must be world-readable,
# directories searchable, and no extended attributes may remain (macOS adds some).
chmod -R u+rwX,go+rX,go-w "$APP_DIR"
if [ "$(uname -s)" = "Darwin" ]; then
  xattr -cr "$APP_DIR" 2>/dev/null || true
fi

# Brewlet keeps modification times in the layer tarballs, so a directory stamped with the build time
# would give an unchanged layer a new digest on every build. Pin every time to one fixed date: a
# code-only change then re-pushes only the code layer.
TZ=UTC find "$APP_DIR" -exec touch -h -t 198002010000 {} +

layer_args=()
layers_file="$dir/layers"
[ -f "$layers_file" ] || layers_file=""
if [ -n "$layers_file" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    src="${line%%:*}"
    dest="${line#*:}"
    [ -d "$APP_DIR/$src" ] || die "$agent: layers entry '$line': $APP_DIR/$src is not a directory"
    layer_args+=(--layer "$APP_DIR/$src:$dest")
  done < "$layers_file"
else
  layer_args+=(--layer "$APP_DIR:/app")
fi

# The tag is cosmetic: deployments pin the digest that scripts/workloads/publish.sh records.
# Each workload has its own store so they can be built in parallel.
ref="$REGISTRY_HOST/$(artifact_repo "$agent"):dev"
store="$out/store"
mkdir -p "$store"

brewlet build "$ref" --platform "linux/$arch" --launch "$dir/launch.json" \
  "${layer_args[@]}" --store "$store" -result "$out/build-result.json"
echo "$ref" > "$out/ref"
ok "$agent artifact built: $ref"
