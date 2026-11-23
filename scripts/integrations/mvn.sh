#!/usr/bin/env bash
# Runs Maven against the shared project-local repository (build/m2), so builds never
# read or write ~/.m2. Uses mvn from PATH, else the Maven Wrapper that ships with the
# pinned integrations (run scripts/integrations/build.sh java first).
#
#   scripts/integrations/mvn.sh -f /absolute/path/to/pom.xml package
#
# Pass absolute paths: the wrapper fallback runs from the integrations directory.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

if command -v mvn >/dev/null 2>&1; then
  exec mvn -B -ntp -Dmaven.repo.local="$BUILD_DIR/m2" "$@"
fi

WRAPPER_DIR="$BUILD_DIR/integrations/src/java/spring-boot"
[ -x "$WRAPPER_DIR/mvnw" ] || die "no Maven found: install Maven 3.9+ or run 'make integrations-java'"
cd "$WRAPPER_DIR"
exec ./mvnw -B -ntp -Dmaven.repo.local="$BUILD_DIR/m2" "$@"
