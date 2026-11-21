#!/usr/bin/env bash
# Builds the Node.js integrations (agent-core, ai, NestJS, Fastify) from the pinned
# copilot-sdk-integrations tree and packs each one into a tarball in build/integrations/node,
# which is where the agents install them from.
# Invoked by scripts/integrations-build.sh, never directly.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"
need node npm

NODEJS="$INTEGRATIONS_SRC/nodejs"
LOG="$INTEGRATIONS_OUT/build.log"
: > "$LOG"
rm -f "$INTEGRATIONS_OUT"/*.tgz

# Build order matters: the other packages compile against the output of core.
PACKAGES="core ai nestjs fastify"
workspaces=()
for pkg in $PACKAGES; do workspaces+=(--workspace "packages/$pkg"); done

# Only the four packages (plus the root's TypeScript) are installed: not the examples, not the web
# app. Install scripts and optional dependencies stay off, because tsc needs neither, and the output
# is plain JavaScript that runs on any Node version the packages support, not just the host's.
# The registry sometimes resets connections; a retry resumes from npm's cache.
log "  npm ci"
retry 3 bash -c 'cd "$1" && shift && npm ci --ignore-scripts --omit=optional --no-audit --no-fund --include-workspace-root "$@"' \
  _ "$NODEJS" "${workspaces[@]}" >> "$LOG" 2>&1 \
  || { tail -40 "$LOG" >&2; die "npm ci failed (full log: $LOG)"; }

for pkg in $PACKAGES; do
  log "  $pkg"
  ( cd "$NODEJS" \
    && npm run build --workspace "packages/$pkg" \
    && npm pack --workspace "packages/$pkg" --pack-destination "$INTEGRATIONS_OUT" ) >> "$LOG" 2>&1 \
    || { tail -40 "$LOG" >&2; die "$pkg build failed (full log: $LOG)"; }
done
