#!/usr/bin/env bash
# Builds the agent into $APP_DIR. Called by scripts/workloads/build.sh, which then packages
# $APP_DIR as a Brewlet application artifact (see the "layers" file next to this script).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
: "${APP_DIR:?run this through scripts/workloads/build.sh}"
: "${ARCH:?run this through scripts/workloads/build.sh}"
: "${INTEGRATIONS_OUT:?run this through scripts/workloads/build.sh}"
need uv

# The runtime is Linux on glibc with CPython 3.13 whatever the build host is, so the dependencies are
# resolved for that platform, as binary wheels only: the runtime has no compiler and no pip.
case "$ARCH" in
  arm64) PLATFORM=aarch64-manylinux_2_28 ;;
  amd64) PLATFORM=x86_64-manylinux_2_28 ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

WHEELS=("$INTEGRATIONS_OUT"/copilot_agent_core-*.whl "$INTEGRATIONS_OUT"/copilot_fastapi-*.whl)
[ -f "${WHEELS[0]}" ] && [ -f "${WHEELS[1]}" ] \
  || die "the integration wheels are missing in $INTEGRATIONS_OUT: run scripts/integrations/build.sh python"

SITE="$APP_DIR/deps/site-packages"
mkdir -p "$SITE" "$APP_DIR/code"

log "installing the dependencies for linux/$ARCH (CPython 3.13)"
retry 3 uv pip install --quiet --python 3.13 --python-version 3.13 --python-platform "$PLATFORM" \
  --only-binary :all: --link-mode copy --target "$SITE" -r "$HERE/requirements.txt" "${WHEELS[@]}"

# Install metadata that only records how and where this host installed the files.
find "$SITE" -path '*.dist-info/*' \( -name INSTALLER -o -name REQUESTED -o -name direct_url.json \) -delete

# Console scripts: the runtime has no shell and the entrypoint is "python -m concierge", and their
# shebangs name this host's interpreter.
rm -rf "${SITE:?}/bin"

# The Copilot CLI belongs to the sidecar container, never to the artifact. A platform wheel of the SDK
# bundles it under copilot/bin; the universal wheel pinned in requirements.txt does not, so this is a guard.
if [ -d "$SITE/copilot/bin" ]; then
  log "removing the bundled Copilot CLI ($(du -sh "$SITE/copilot/bin" | cut -f1))"
  rm -rf "$SITE/copilot/bin"
fi

cp -R "$HERE/src/concierge" "$APP_DIR/code/concierge"
find "$APP_DIR/code" -name __pycache__ -prune -exec rm -rf {} +

# The root filesystem is read-only, so Python cannot cache bytecode at run time: ship it. The hashes are
# unchecked because the build pins every file's modification time, which would invalidate timestamped .pyc
# files. -s/-p record the path each file has in the Pod (/app/...) instead of the one on this host; -d would
# flatten the sub-directories.
compile() {
  uv run --no-project --python 3.13 python -m compileall -q -j 0 --invalidation-mode unchecked-hash \
    -s "$APP_DIR/$1" -p /app "$2"
}
compile deps "$SITE"
compile code "$APP_DIR/code/concierge"
