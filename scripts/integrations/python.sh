#!/usr/bin/env bash
# Builds the Python integrations (copilot-agent-core, copilot-fastapi, copilot-django) into
# wheels in build/integrations/python, which is where the agents resolve them.
# Invoked by scripts/integrations-build.sh, never directly.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"
need uv

PYTHON="$INTEGRATIONS_SRC/python"
LOG="$INTEGRATIONS_OUT/build.log"
: > "$LOG"
rm -f "$INTEGRATIONS_OUT"/*.whl

# The host python3 is usually older than the integrations require, so uv fetches CPython 3.13
# (the runtime's version) and the build backend on demand. PyPI sometimes resets connections;
# a retry resumes from uv's cache.
build() {
  local name="$1" dir="$2"
  log "  $name"
  retry 3 uv build --wheel --python 3.13 --out-dir "$INTEGRATIONS_OUT" "$PYTHON/$dir" >> "$LOG" 2>&1 \
    || { tail -40 "$LOG" >&2; die "$name build failed (full log: $LOG)"; }
}

build "agent core"           core
build "FastAPI integration"  fastapi
build "Django integration"   django
