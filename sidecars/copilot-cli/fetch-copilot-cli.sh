#!/bin/sh
# Installs the Copilot CLI into the sidecar image (see Dockerfile).
#
# Every Copilot SDK talks to the CLI, but no SDK ships it. In this repository
# the CLI lives in one shared sidecar container, so the platform team owns its
# version and the agent artifacts carry none of it.
#
# This script downloads the release's runtime package, verifies the SHA-256
# pinned in versions.env, and keeps the same "hostless" subset the official
# SDKs install:
#   <dest>/copilot-runtime   launcher that serves the SDK protocol (--headless)
#   <dest>/runtime.node      the CLI itself, loaded by the launcher
#   <dest>/{ripgrep,tgrep,builtin,definitions,schemas,plugins,...}
# Terminal UI assets, voice, tree-sitter grammars and other platforms' binaries
# are dropped (see _HOSTLESS_EXCLUDED_TOP_LEVEL in the Python SDK).
#
# Environment: COPILOT_CLI_VERSION, TARGETARCH (amd64|arm64),
#              COPILOT_CLI_SHA256_LINUX_{ARM64,X64}, DEST (default /opt/copilot/cli)
set -eu

: "${COPILOT_CLI_VERSION:?}" "${TARGETARCH:?}"
DEST="${DEST:-/opt/copilot/cli}"

case "$TARGETARCH" in
  amd64) platform=linux-x64;   expected="${COPILOT_CLI_SHA256_LINUX_X64:?}" ;;
  arm64) platform=linux-arm64; expected="${COPILOT_CLI_SHA256_LINUX_ARM64:?}" ;;
  *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;;
esac

asset="github-copilot-${COPILOT_CLI_VERSION}-${platform}.tgz"
url="https://github.com/github/copilot-cli/releases/download/v${COPILOT_CLI_VERSION}/${asset}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "fetching $url"
curl -fsSL --retry 3 -o "$work/$asset" "$url"
echo "${expected}  $work/$asset" | sha256sum -c -

mkdir "$work/pkg"
tar -xzf "$work/$asset" -C "$work/pkg" --strip-components=1
cd "$work/pkg"

rm -rf app.js assets changelog.json cli-main.js copilot copilot.exe copilot-sdk \
  foundry-local-sdk index.js LICENSE.md napi-oop-runtime npm-loader.js package.json \
  preloads pvrecorder queries README.md sdk sea-loader.js webview
rm -f tree-sitter*.wasm voice-*.js
find . -name cli-native.node -delete
find . -name 'copilot-runtime-bin*' -delete
find . -name mediaremote-adapter -prune -exec rm -rf {} +

# Flatten prebuilds/<platform>/* next to the launcher and drop other platforms.
platform_dir="prebuilds/${platform}"
[ -f "${platform_dir}/copilot-runtime" ] || { echo "missing ${platform_dir}/copilot-runtime" >&2; exit 1; }
find "$platform_dir" -mindepth 1 -maxdepth 1 -exec mv {} . \;
rm -rf prebuilds

[ -s copilot-runtime ] && [ -s runtime.node ] || { echo "incomplete runtime bundle" >&2; exit 1; }

# The sidecar runs as an unprivileged user that owns nothing: readable by all,
# writable by none, no setuid/setgid bits.
chmod -R u+rwX,go+rX,go-w,a-s .
chmod 0755 copilot-runtime

mkdir -p "$DEST"
cp -a . "$DEST/"
echo "installed Copilot CLI ${COPILOT_CLI_VERSION} (${platform}) into $DEST: $(du -sh "$DEST" | cut -f1)"
