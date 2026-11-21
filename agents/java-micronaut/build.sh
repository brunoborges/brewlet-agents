#!/usr/bin/env bash
# Builds the agent into $APP_DIR. Called by scripts/agent-build.sh, which then packages
# $APP_DIR as a Brewlet application artifact (see the "layers" file next to this script).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
: "${APP_DIR:?run this through scripts/agent-build.sh}"

"$ROOT/scripts/mvn.sh" -f "$HERE/pom.xml" -DskipTests clean package

# Maven leaves a thin app.jar and the dependency jars in target/lib. The jar finds its libraries
# through its manifest Class-Path (lib/*.jar), so Brewlet can ship the libraries and the code as
# separate layers.
mkdir -p "$APP_DIR/deps/lib" "$APP_DIR/code"
cp "$HERE"/target/lib/*.jar "$APP_DIR/deps/lib/"
cp "$HERE/target/app.jar" "$APP_DIR/code/app.jar"

# Brewlet keeps file times in the layer tarballs. Pin them (files and directories) so an unchanged
# dependency set always produces the same "deps" layer digest and a code change only touches "code".
TZ=UTC find "$APP_DIR" -exec touch -t 198002010000 {} +
