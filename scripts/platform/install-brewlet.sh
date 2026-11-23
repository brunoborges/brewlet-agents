#!/usr/bin/env bash
# Installs the pinned Brewlet CLI into ./.bin (never system-wide).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need curl

BIN="$ROOT/.bin/brewlet"
if [ -x "$BIN" ] && "$BIN" version 2>/dev/null | grep -q "$BREWLET_VERSION"; then
  ok "brewlet CLI $BREWLET_VERSION already installed ($BIN)"
  exit 0
fi

log "installing Brewlet CLI $BREWLET_VERSION into $ROOT/.bin"
mkdir -p "$ROOT/.bin"
curl -fsSL https://brewlet.sh/install.sh \
  | BREWLET_INSTALL_DIR="$ROOT/.bin" sh -s -- --version "$BREWLET_VERSION"
"$BIN" version
