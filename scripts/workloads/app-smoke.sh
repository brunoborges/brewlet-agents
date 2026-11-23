#!/usr/bin/env bash
# Black-box check of a deployed app through a port-forward to its Service.
#
#   scripts/workloads/app-smoke.sh <app>
#
# Every app has to answer HEALTH_PATH (app.env; /healthz by default) with 200 on SERVICE_PORT
# (app.env; 80 by default). Then the app's own checks run: agents/wikipedia/<app>/smoke.sh <base-url>, if it
# has one. Set REQUIRE_AUTH=1 to make the checks that need the Copilot CLI's credentials mandatory
# instead of optional ('make auth' provides them).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/smoke.sh"
need kubectl curl jq

app="${1:-}"
[ -n "$app" ] || die "usage: $(basename "$0") <app>"
dir="$(agent_dir "$app")"
envfile="$(workload_env "$dir")"
namespace="$(workload_namespace "$app")"
health="$(env_value "$envfile" HEALTH_PATH)"
port="$(env_value "$envfile" SERVICE_PORT)"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

trap forward_stop EXIT
forward_start "$namespace" "$app" "${port:-80}"
base="http://127.0.0.1:$FORWARD_PORT"

log "smoke-testing $app at $base"
call GET "${health:-/healthz}"
expect "GET ${health:-/healthz} answers 200" 200
if any_failed; then die "$app does not answer ${health:-/healthz}"; fi

if [ -x "$dir/smoke.sh" ]; then
  # It reports its own result, and its failure ends this script too.
  "$dir/smoke.sh" "$base"
else
  smoke_result "$app"
fi
