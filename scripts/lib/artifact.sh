#!/usr/bin/env bash
# Sourced by the example's build.sh, which stages its files between these two calls.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

prepare_artifact() {
  local dir="$1" name="${1##*/}" envfile language runtime integrations
  [ "$(agent_dir "$name")" = "$dir" ] || die "not an example directory: $dir"
  envfile="$(workload_env "$dir")"
  language="$(env_value "$envfile" LANGUAGE)"
  runtime="$(env_value "$envfile" RUNTIME)"
  [ -n "$language" ] && [ -n "$runtime" ] || die "$envfile needs LANGUAGE and RUNTIME"
  grep -q "\"$runtime\"" "$dir/launch.json" || die "$dir/launch.json must list runtime $runtime"
  [ -x "$ROOT/.bin/brewlet" ] || die "Brewlet CLI missing: run scripts/platform/install-brewlet.sh from the repository root"
  need docker
  ARCH="$(host_arch)"
  if [ -f "$dir/agent.env" ]; then integrations="$language"; else integrations="$(env_value "$envfile" INTEGRATIONS)"; fi
  if [ -n "$integrations" ]; then
    "$ROOT/scripts/integrations/build.sh" "$integrations"
    export INTEGRATIONS_OUT="$BUILD_DIR/integrations/$integrations"
  fi

  local out
  out="$(artifact_out "$name")"
  APP_DIR="$out/app"
  rm -rf "$out"
  mkdir -p "$APP_DIR"
  export APP_DIR ARCH
  log "building $name ($language, runtime $runtime, linux/$ARCH)"
}

package_artifact() {
  local dir="$1" name="${1##*/}" out="${APP_DIR%/app}" line src dest ref
  local layer_args=()
  # Brewlet rejects unsafe modes and macOS attributes, and includes mtimes in layer digests.
  chmod -R u+rwX,go+rX,go-w "$APP_DIR"
  if [ "$(uname -s)" = "Darwin" ]; then xattr -cr "$APP_DIR" 2>/dev/null || true; fi
  TZ=UTC find "$APP_DIR" -exec touch -h -t 198002010000 {} +

  if [ -f "$dir/layers" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      src="${line%%:*}"
      dest="${line#*:}"
      [ -d "$APP_DIR/$src" ] || die "$name: layers entry '$line': $APP_DIR/$src is not a directory"
      layer_args+=(--layer "$APP_DIR/$src:$dest")
    done < "$dir/layers"
  else
    layer_args+=(--layer "$APP_DIR:/app")
  fi

  ref="$REGISTRY_HOST/$(artifact_repo "$name"):dev"
  mkdir -p "$out/store"
  brewlet build "$ref" --platform "linux/$ARCH" --launch "$dir/launch.json" \
    "${layer_args[@]}" --store "$out/store" -result "$out/build-result.json"
  echo "$ref" > "$out/ref"
  ok "$name artifact built: $ref"
}
