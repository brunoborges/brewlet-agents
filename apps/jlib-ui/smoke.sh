#!/usr/bin/env bash
# The jlib-ui's own checks, run by scripts/workloads/app-smoke.sh against the deployed Service. They also work
# by hand against any instance:
#
#   apps/jlib-ui/smoke.sh http://localhost:3000
#
# They only read. The WebSocket on port 3001 is not covered: the smoke test forwards one port.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/smoke.sh"
need curl jq

base="${1:-}"
[ -n "$base" ] || die "usage: $(basename "$0") <base-url>"

# The dashboard asks the server every ten seconds, and once at start-up; give a fresh Pod a moment.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  call GET /api/health
  [ "$(printf '%s' "$body" | jq -r '.jlibServerStatus // empty' 2>/dev/null)" != connected ] || break
  sleep 2
done
expect "the dashboard reaches the jlib-inspector server" 200 '.status == "healthy" and .jlibServerStatus == "connected"'

call GET /
if [ "$code" = 200 ] && printf '%s' "$body" | grep -q 'bundle.js'; then
  pass "GET / serves the page that loads the bundle"
else
  fail "GET / serves the page that loads the bundle: HTTP $code ${body:0:200}"
fi

call GET /bundle.js
expect "GET /bundle.js is served" 200

call GET /api/apps
expect "GET /api/apps lists the applications the server knows" 200 'type == "array"'

call GET /api/apps/no-such-application
expect "an application that never reported is a 404" 404

smoke_result jlib-ui
