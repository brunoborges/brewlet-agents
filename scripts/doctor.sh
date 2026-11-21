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

log "docker resources"
# The cluster, the registry and all eight agents take about 3 GiB of the Docker VM. Docker reports a
# little less than it was given (a 4 GiB VM shows about 3.75 GiB), so the warning starts at 3.5 GiB.
docker_mib="$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{ printf "%d", $1 / 1048576 }')"
case "$docker_mib" in
  '' | *[!0-9]*) printf '  \033[33m-\033[0m %-9s could not read the memory of the Docker VM\n' memory ;;
  *)
    if [ "$docker_mib" -ge 3584 ]; then
      printf '  \033[32m✓\033[0m %-9s %s MiB for Docker\n' memory "$docker_mib"
    else
      printf '  \033[33m!\033[0m %-9s Docker has %s MiB; give it 4 GiB (Docker Desktop: Settings, Resources) to run all eight agents\n' memory "$docker_mib"
    fi
    ;;
esac

too_old() { # too_old TOOL MIN-MAJOR PURPOSE: reads TOOL's major version on stdin, warns when it is lower
  local tool="$1" want="$2" purpose="$3" have
  have="$(cat)"
  case "$have" in '' | *[!0-9]*) return 0 ;; esac
  [ "$have" -ge "$want" ] \
    || printf '    \033[33m!\033[0m %s %s is too old for %s: it needs %s or newer\n' "$tool" "$have" "$purpose" "$want"
}

log "language toolchains (needed per agent)"
optional java "the Java agents (JDK 25)" java -version
java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n1 | too_old java 25 "the Java agents"
optional node "the Node.js agents (Node 24 or newer)" node --version
node --version 2>/dev/null | sed -n 's/^v\([0-9]*\).*/\1/p' | too_old node 24 "the Node.js agents"
optional npm "the Node.js agents" npm --version
optional uv "the Python agents (it fetches Python 3.13 and the wheels, so no system Python is needed)" uv --version
optional dotnet "the .NET agent (.NET 10 SDK)" dotnet --version
dotnet --version 2>/dev/null | sed -n 's/^\([0-9]*\)\..*/\1/p' | too_old dotnet 10 "the .NET agent"
optional mvn "the Java agents (the Maven Wrapper of the integrations is used otherwise)" mvn --version

log "make check (optional)"
if command -v ruby >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m %-9s %s\n' ruby "$(ruby --version 2>&1 | head -n1)"
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m %-9s with PyYAML\n' python3
else
  printf '  \033[33m-\033[0m %-9s not found (make check parses YAML with Ruby, or with Python and PyYAML)\n' ruby
fi
optional shellcheck "make check (lints the scripts; skipped without it)" shellcheck --version

log "cluster"
if [ -f "$KUBECONFIG" ] && kube get nodes >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m cluster   %s is reachable\n' "kind-$CLUSTER_NAME"
else
  printf '  \033[33m-\033[0m cluster   %s is not running (make cluster)\n' "kind-$CLUSTER_NAME"
fi

[ "$missing" -eq 0 ] || die "install the missing tools above"
ok "the platform tools are in place"
