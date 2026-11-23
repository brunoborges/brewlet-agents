#!/usr/bin/env bash
# Builds the app into $APP_DIR. Called by scripts/workloads/build.sh, which then packages
# $APP_DIR as a Brewlet application artifact (see the "layers" file next to this script).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib/common.sh"
: "${APP_DIR:?run this through scripts/workloads/build.sh}"
need node

# The tests are part of the build; they need no network and no summarizer.
LOG="$(dirname "$APP_DIR")/test.log"
log "  node --test"
( cd "$HERE" && node --test ) > "$LOG" 2>&1 || { tail -40 "$LOG" >&2; die "the tests failed (full log: $LOG)"; }

# The app has no dependencies: the artifact is its code. package.json comes along because its
# "type": "module" makes Node load /app/src/*.js as ES modules.
mkdir -p "$APP_DIR/code"
cp "$HERE/package.json" "$APP_DIR/code/"
cp -R "$HERE/src" "$HERE/public" "$APP_DIR/code/"
