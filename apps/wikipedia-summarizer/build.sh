#!/usr/bin/env bash
# Build the wikipedia-summarizer Brewlet artifact using the layers and launch.json in this directory.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib/artifact.sh"
prepare_artifact "$HERE"

# The unit tests run as part of the build; they need no network and no Copilot CLI.
"$ROOT/scripts/integrations/mvn.sh" -f "$HERE/pom.xml" clean package

# Spring Boot's "tools" mode splits the fat jar into a thin app.jar plus lib/*.jar. The
# thin jar finds its libraries through its manifest Class-Path, so Brewlet can ship the
# libraries and the code as separate layers.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
java -Djarmode=tools -jar "$HERE/target/app.jar" extract --destination "$STAGE"

mkdir -p "$APP_DIR/deps" "$APP_DIR/code"
mv "$STAGE/lib" "$APP_DIR/deps/lib"
mv "$STAGE/app.jar" "$APP_DIR/code/app.jar"

package_artifact "$HERE"
