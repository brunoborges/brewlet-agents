#!/usr/bin/env bash
# Build the jlib-ui Brewlet artifact using the layers and launch.json in this directory.
#
# The app is the dashboard of jlib-inspector: the frontend/ directory of that repository, an Express
# server and a React bundle. None of it is kept here. The build fetches the commit that versions.env
# pins, lets webpack build the bundle, and puts into the artifact only what runs: app.js, the bundle,
# and the five packages app.js requires. Webpack, Babel and React stay behind in the build tree.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib/artifact.sh"
prepare_artifact "$HERE"
need git node npm jq

case "$ARCH" in
  amd64) CPU=x64 ;;
  arm64) CPU=arm64 ;;
  *) die "unsupported ARCH: $ARCH" ;;
esac

SRC="$BUILD_DIR/jlib-inspector/$JLIB_INSPECTOR_COMMIT"
FRONTEND="$SRC/frontend"
STAGE="$(dirname "$APP_DIR")/run-time-deps"
LOG="$(dirname "$APP_DIR")/npm.log"
: > "$LOG"

# Fetching a commit by its hash and checking what came back means the build gets exactly that commit,
# whatever happens to the tag or the branch.
if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$JLIB_INSPECTOR_COMMIT" ]; then
  log "  fetching jlib-inspector $JLIB_INSPECTOR_COMMIT"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  retry 3 git -C "$SRC" fetch -q --depth 1 https://github.com/brunoborges/jlib-inspector.git "$JLIB_INSPECTOR_COMMIT"
  git -C "$SRC" checkout -q --detach FETCH_HEAD
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$JLIB_INSPECTOR_COMMIT" ] \
    || die "fetched a commit other than the $JLIB_INSPECTOR_COMMIT that versions.env pins"
fi
# Start every build from the commit alone, without the previous build's node_modules and dist.
git -C "$SRC" reset -q --hard "$JLIB_INSPECTOR_COMMIT"
git -C "$SRC" clean -q -ffdx

npm_step() {
  local what="$1" dir="$2"; shift 2
  log "  $what"
  ( cd "$dir" && "$@" ) >> "$LOG" 2>&1 \
    || { tail -40 "$LOG" >&2; die "$what failed (full log: $LOG)"; }
}

# No lockfile, as in agents/node-fastify: the one upstream ships records the URLs of a private feed,
# so versions float within the ranges that upstream's package.json declares. Install scripts stay off:
# none of what is built needs one.
NPM_FLAGS=(--ignore-scripts --no-package-lock --no-audit --no-fund)

# The bundle is plain JavaScript, so it is built for the host.
npm_step "npm install (build tools)" "$FRONTEND" retry 3 npm install "${NPM_FLAGS[@]}"
npm_step "webpack" "$FRONTEND" npm run build:only
[ -f "$FRONTEND/dist/index.html" ] && [ -f "$FRONTEND/dist/bundle.js" ] \
  || die "webpack did not produce dist/index.html and dist/bundle.js (full log: $LOG)"

# Upstream lists its build tools under "dependencies" too. The run-time packages are installed from a
# package.json of their own, resolved for the artifact's platform rather than the host's.
rm -rf "$STAGE" "$APP_DIR/deps" "$APP_DIR/code"
mkdir -p "$STAGE" "$APP_DIR/deps" "$APP_DIR/code"
jq '{
      name: "jlib-ui",
      version: .version,
      private: true,
      dependencies: (.dependencies | with_entries(select(.key | IN("axios", "cors", "express", "node-cron", "ws")))),
      overrides: .overrides
    }' "$FRONTEND/package.json" > "$STAGE/package.json"
[ "$(jq '.dependencies | length' "$STAGE/package.json")" -eq 5 ] \
  || die "upstream's package.json no longer declares the five packages that app.js requires"
npm_step "npm install (run time)" "$STAGE" retry 3 npm install --omit=dev --omit=optional \
  --os=linux "--cpu=$CPU" --libc=glibc "${NPM_FLAGS[@]}"

# The dependencies layer holds package.json next to node_modules, as in a normal project.
mv "$STAGE/node_modules" "$APP_DIR/deps/node_modules"
# npm's hidden lockfile only speeds up npm; it records the registry's URLs and the tarballs' paths.
rm -f "$APP_DIR/deps/node_modules/.package-lock.json"
cp "$STAGE/package.json" "$APP_DIR/deps/package.json"
rm -rf "$STAGE"

cp "$FRONTEND/app.js" "$APP_DIR/code/app.js"
cp -R "$FRONTEND/dist" "$APP_DIR/code/dist"
# The MIT license asks for its notice to travel with copies of the code.
cp "$SRC/LICENSE" "$APP_DIR/code/LICENSE"

# The runtime is Node 24 on glibc. A native addon would have to match both, and none is expected.
addon="$(find "$APP_DIR" -name '*.node' -print -quit)"
[ -z "$addon" ] || die "native addon in the artifact: $addon (it must be built for linux/glibc and Node 24)"

package_artifact "$HERE"
