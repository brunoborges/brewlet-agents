#!/usr/bin/env bash
# Builds the agent into $APP_DIR. Called by scripts/agent-build.sh, which then packages
# $APP_DIR as a Brewlet application artifact (see the "layers" file next to this script).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib.sh"
: "${APP_DIR:?run this through scripts/agent-build.sh}"
: "${ARCH:?run this through scripts/agent-build.sh}"
need node npm

case "$ARCH" in
  amd64) CPU=x64 ;;
  arm64) CPU=arm64 ;;
  *) die "unsupported ARCH: $ARCH" ;;
esac

LOG="$(dirname "$APP_DIR")/npm.log"
: > "$LOG"

# Resolve for the artifact's platform, not the host's, and keep out of it:
#  - the optional per-platform Copilot runtime (about 200 MB) that the SDK ships for in-process
#    use. This agent talks to the CLI in the sidecar over TCP and never loads it;
#  - install scripts, which would otherwise compile or download for the host.
# No lockfile: the registry here may be a mirror whose URLs a lockfile would record and that do not
# resolve elsewhere, and the integration tarballs are a build output under build/.
NPM_FLAGS=(--os=linux "--cpu=$CPU" --libc=glibc --omit=optional --ignore-scripts
           --no-package-lock --no-audit --no-fund)

npm_step() {
  local what="$1"; shift
  log "  $what"
  ( cd "$HERE" && "$@" ) >> "$LOG" 2>&1 \
    || { tail -40 "$LOG" >&2; die "$what failed (full log: $LOG)"; }
}

rm -rf "$HERE/node_modules" "$HERE/dist" "$APP_DIR/deps" "$APP_DIR/code"

# The registry sometimes resets connections; a retry resumes from npm's cache.
npm_step "npm install" retry 3 npm install "${NPM_FLAGS[@]}"
npm_step "tsc" npm run build
npm_step "npm prune" npm prune --omit=dev "${NPM_FLAGS[@]}"

# The dependencies layer holds package.json next to node_modules, as in a normal project. It also
# carries "type": "module", which makes Node load /app/dist/*.js as ES modules.
mkdir -p "$APP_DIR/deps" "$APP_DIR/code"
mv "$HERE/node_modules" "$APP_DIR/deps/node_modules"
# npm's hidden lockfile only speeds up npm; it records the registry's URLs and the tarballs' paths.
rm -f "$APP_DIR/deps/node_modules/.package-lock.json"
cp "$HERE/package.json" "$APP_DIR/deps/package.json"
mv "$HERE/dist" "$APP_DIR/code/dist"
cp -R "$HERE/prompts" "$APP_DIR/code/prompts"

# The runtime is Node 24 on glibc. A native addon would have to match both, and none is expected.
addon="$(find "$APP_DIR" -name '*.node' -print -quit)"
[ -z "$addon" ] || die "native addon in the artifact: $addon (it must be built for linux/glibc and Node 24)"
