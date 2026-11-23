#!/usr/bin/env bash
# Builds the app into $APP_DIR. Called by scripts/agent-build.sh, which then packages
# $APP_DIR as a Brewlet application artifact (see the "layers" file next to this script).
#
# Nothing is compiled: the server is the release jar of jlib-inspector, taken from its GitHub
# release and checked against the SHA-256 in versions.env before it goes into the artifact.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib.sh"
: "${APP_DIR:?run this through scripts/agent-build.sh}"
need curl openssl

JAR="jlib-inspector-server-${JLIB_INSPECTOR_VERSION}-shaded.jar"
URL="https://github.com/brunoborges/jlib-inspector/releases/download/v${JLIB_INSPECTOR_VERSION}/$JAR"
CACHE="$BUILD_DIR/downloads"
mkdir -p "$CACHE"

sha256() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }

if [ ! -f "$CACHE/$JAR" ] || [ "$(sha256 "$CACHE/$JAR")" != "$JLIB_INSPECTOR_SHA256_SERVER" ]; then
  log "  downloading $JAR"
  rm -f "$CACHE/$JAR.part"
  curl -fsSL --retry 5 --retry-all-errors -o "$CACHE/$JAR.part" "$URL"
  actual="$(sha256 "$CACHE/$JAR.part")"
  if [ "$actual" != "$JLIB_INSPECTOR_SHA256_SERVER" ]; then
    rm -f "$CACHE/$JAR.part"
    die "$JAR has SHA-256 $actual, but versions.env pins $JLIB_INSPECTOR_SHA256_SERVER"
  fi
  mv "$CACHE/$JAR.part" "$CACHE/$JAR"
fi

mkdir -p "$APP_DIR/app"
cp "$CACHE/$JAR" "$APP_DIR/app/jlib-inspector-server.jar"
cp "$HERE/logging.properties" "$APP_DIR/app/"
