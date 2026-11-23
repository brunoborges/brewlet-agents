#!/usr/bin/env bash
# The jlib-inspector server's own checks, run by scripts/app-smoke.sh against the deployed Service.
# They also work by hand against any instance:
#
#   apps/jlib-server/smoke.sh http://localhost:8080
#
# They only read. The applications that report to the server are whatever happens to be deployed,
# so these checks do not depend on any of them, and nothing is written that could not be removed
# again: the server has no way to delete an application.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/smoke-lib.sh"
need curl jq

base="${1:-}"
[ -n "$base" ] || die "usage: $(basename "$0") <base-url>"

call GET /api/dashboard
expect "GET /api/dashboard returns the dashboard document" 200 '(.applicationCount | type == "number") and (.applications | type == "array")'

call GET /api/apps
expect "GET /api/apps lists the applications that reported" 200 '.applications | type == "array"'

call GET /api/jars
expect "GET /api/jars lists the jars they reported" 200 '.jars | type == "array"'

call GET /api/apps/no-such-application
expect "an application that never reported is a 404" 404

smoke_result jlib-server
