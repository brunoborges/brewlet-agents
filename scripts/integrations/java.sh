#!/usr/bin/env bash
# Installs the Java integrations (Spring Boot, Quarkus, Micronaut) into the shared
# project-local Maven repository build/m2, which is where the agents resolve them.
# Invoked by scripts/integrations-build.sh, never directly.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"
need java

JAVA="$INTEGRATIONS_SRC/java"
LOG="$INTEGRATIONS_OUT/build.log"
: > "$LOG"

# Each integration ships its own Maven Wrapper, so no local Maven is needed here.
mvnw_install() {
  local dir="$1"; shift
  ( cd "$JAVA/$dir" && ./mvnw -B -ntp -Dmaven.repo.local="$BUILD_DIR/m2" "$@" -DskipTests install )
}

# Maven Central sometimes resets connections; a retry resumes from what is already in build/m2.
build() {
  local name="$1" dir="$2"; shift 2
  log "  $name"
  retry 3 mvnw_install "$dir" "$@" >> "$LOG" 2>&1 \
    || { tail -40 "$LOG" >&2; die "$name build failed (full log: $LOG)"; }
}

build "Spring Boot starter" spring-boot -pl copilot-spring-boot-starter -am
build "Quarkus extension"   quarkus     -pl deployment -am
build "Micronaut module"    micronaut   -pl runtime,processor -am
