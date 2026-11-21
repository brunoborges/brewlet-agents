#!/usr/bin/env bash
# Builds one language's integrations from the pinned copilot-sdk-integrations commit.
#
#   scripts/integrations-build.sh java|node|python|dotnet
#
# The integrations are not published to a package registry yet, so this fetches
# the exact commit pinned in versions.env and builds it into build/integrations/<lang>/.
# Agents consume the result and bundle it into their own artifact; no runtime has it.
# Re-running is free once a language is built for the pinned commit.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need curl tar

lang="${1:-}"
script="$ROOT/scripts/integrations/$lang.sh"
[ -n "$lang" ] && [ -f "$script" ] || die "usage: $(basename "$0") <java|node|python|dotnet>"

SRC="$BUILD_DIR/integrations/src"
if [ "$(cat "$SRC/.sha" 2>/dev/null || true)" != "$INTEGRATIONS_SHA" ]; then
  log "fetching $INTEGRATIONS_REPO @ ${INTEGRATIONS_SHA:0:12}"
  rm -rf "$BUILD_DIR/integrations"
  mkdir -p "$SRC"
  curl -fsSL "https://github.com/$INTEGRATIONS_REPO/archive/$INTEGRATIONS_SHA.tar.gz" \
    | tar -xz --strip-components=1 -C "$SRC"
  echo "$INTEGRATIONS_SHA" > "$SRC/.sha"
fi

OUT="$BUILD_DIR/integrations/$lang"
mkdir -p "$OUT"
if [ -f "$OUT/.built" ] && [ "$(cat "$OUT/.built")" = "$INTEGRATIONS_SHA" ]; then
  ok "$lang integrations already built (${INTEGRATIONS_SHA:0:12})"
  exit 0
fi

export INTEGRATIONS_SRC="$SRC" INTEGRATIONS_OUT="$OUT"
log "building $lang integrations"
bash "$script"
echo "$INTEGRATIONS_SHA" > "$OUT/.built"
ok "$lang integrations built into ${OUT#"$ROOT"/}"
