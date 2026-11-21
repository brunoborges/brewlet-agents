#!/usr/bin/env bash
# Builds the agent into $APP_DIR. Called by scripts/agent-build.sh, which then packages
# $APP_DIR as a Brewlet application artifact (see the "layers" file next to this script).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
: "${APP_DIR:?run this through scripts/agent-build.sh}"

"$ROOT/scripts/mvn.sh" -f "$HERE/pom.xml" -DskipTests clean package

# Spring Boot's "tools" mode splits the fat jar into a thin app.jar plus lib/*.jar. The
# thin jar finds its libraries through its manifest Class-Path, so Brewlet can ship the
# libraries and the code as separate layers.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
java -Djarmode=tools -jar "$HERE/target/app.jar" extract --destination "$STAGE"

mkdir -p "$APP_DIR/deps" "$APP_DIR/code"
mv "$STAGE/lib" "$APP_DIR/deps/lib"
mv "$STAGE/app.jar" "$APP_DIR/code/app.jar"
