#!/usr/bin/env bash
# Build the java-micronaut Brewlet artifact using the layers and launch.json in this directory.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../scripts/lib/artifact.sh"
prepare_artifact "$HERE"

"$ROOT/scripts/integrations/mvn.sh" -f "$HERE/pom.xml" -DskipTests clean package

# Maven leaves a thin app.jar and the dependency jars in target/lib. The jar finds its libraries
# through its manifest Class-Path (lib/*.jar), so Brewlet can ship the libraries and the code as
# separate layers.
mkdir -p "$APP_DIR/deps/lib" "$APP_DIR/code"
cp "$HERE"/target/lib/*.jar "$APP_DIR/deps/lib/"
cp "$HERE/target/app.jar" "$APP_DIR/code/app.jar"

package_artifact "$HERE"
