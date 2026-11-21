#!/usr/bin/env bash
# Builds one agent into a Brewlet application artifact: its code, its dependencies and its
# launch.json, and nothing else. The language runtime and the Copilot CLI are not in it.
#
#   scripts/agent-build.sh <agent>
#
# The artifact lands in a local Brewlet store (build/agents/<agent>/store); scripts/agent-publish.sh
# pushes it. Per-agent inputs live in agents/<agent>/: agent.env, build.sh, launch.json and an
# optional "layers" file.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need docker

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent>"
dir="$(agent_dir "$agent")"
language="$(env_value "$dir/agent.env" LANGUAGE)"
runtime="$(env_value "$dir/agent.env" RUNTIME)"
[ -n "$language" ] && [ -n "$runtime" ] || die "$agent: agent.env needs LANGUAGE and RUNTIME"
[ -f "$dir/launch.json" ] || die "$agent: missing launch.json"
grep -q "\"$runtime\"" "$dir/launch.json" \
  || die "$agent: launch.json runtimeImages must list the runtime id \"$runtime\" from agent.env"
[ -x "$ROOT/.bin/brewlet" ] || die "Brewlet CLI missing: run 'make cluster' (scripts/install-brewlet.sh) first"

arch="$(host_arch)"
"$ROOT/scripts/integrations-build.sh" "$language"

out="$BUILD_DIR/agents/$agent"
APP_DIR="$out/app"
rm -rf "$out"
mkdir -p "$APP_DIR"
export APP_DIR ARCH="$arch" INTEGRATIONS_OUT="$BUILD_DIR/integrations/$language"

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

# The tag is cosmetic: deployments pin the digest that scripts/agent-publish.sh records.
# Each agent has its own store so agents can be built in parallel.
ref="$REGISTRY_HOST/agents/$agent:dev"
store="$out/store"
mkdir -p "$store"

brewlet build "$ref" --platform "linux/$arch" --launch "$dir/launch.json" \
  "${layer_args[@]}" --store "$store" -result "$out/build-result.json"
echo "$ref" > "$out/ref"
ok "$agent artifact built: $ref"
