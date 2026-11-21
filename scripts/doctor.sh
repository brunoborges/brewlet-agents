#!/usr/bin/env bash
# Checks the host for everything this repository needs and says what is missing.
#
#   scripts/doctor.sh
#
# Platform tools are required. Language toolchains are only needed for the agents written in that
# language, so a missing one is a warning, not a failure.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

missing=0
require() { # require TOOL VERSION-COMMAND
  local tool="$1"; shift
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %-9s %s\n' "$tool" "$("$@" 2>&1 | head -n1)"
  else
    printf '  \033[31m✗\033[0m %-9s not found\n' "$tool" >&2
    missing=1
  fi
}
optional() { # optional TOOL FOR VERSION-COMMAND
  local tool="$1" purpose="$2"; shift 2
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %-9s %s\n' "$tool" "$("$@" 2>&1 | head -n1)"
  else
    printf '  \033[33m-\033[0m %-9s not found (only needed for %s)\n' "$tool" "$purpose"
  fi
}

log "platform tools (required)"
require docker docker version --format 'Docker {{.Server.Version}} ({{.Server.Arch}})'
require kind kind version
require kubectl kubectl version --client
require helm helm version --short
require jq jq --version
require curl sh -c 'curl --version | head -n1'
require openssl openssl version

log "language toolchains (needed per agent)"
optional java "the Java agents (JDK 25)" java -version
optional node "the Node.js agents (Node 24 or newer)" node --version
optional npm "the Node.js agents" npm --version
optional python3 "the Python agents" python3 --version
optional uv "the Python agents (fetches Python 3.13 and the wheels)" uv --version
optional dotnet "the .NET agent (.NET 10 SDK)" dotnet --version
optional mvn "the Java agents (the Maven Wrapper of the integrations is used otherwise)" mvn --version

log "cluster"
if [ -f "$KUBECONFIG" ] && kube get nodes >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m cluster   %s is reachable\n' "kind-$CLUSTER_NAME"
else
  printf '  \033[33m-\033[0m cluster   %s is not running (make cluster)\n' "kind-$CLUSTER_NAME"
fi

[ "$missing" -eq 0 ] || die "install the missing tools above"
ok "the platform tools are in place"
