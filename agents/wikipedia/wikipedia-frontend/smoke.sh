#!/usr/bin/env bash
# The wikipedia-frontend's own checks, run by scripts/workloads/app-smoke.sh against the deployed Service. They
# also work by hand against any instance:
#
#   agents/wikipedia/wikipedia-frontend/smoke.sh http://localhost:3000
#
# The front-end only relays to the wikipedia-summarizer, so these checks prove the wiring between
# the two. The last one summarizes a real article through both; without credentials it expects the
# documented 503, unless REQUIRE_AUTH=1 makes the credentials mandatory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../../scripts/lib/smoke.sh"
need curl jq

base="${1:-}"
[ -n "$base" ] || die "usage: $(basename "$0") <base-url>"

for asset in / /app.js /styles.css; do
  call GET "$asset"
  expect "GET $asset is served" 200
done

call POST /api/summaries 'not json'
expect "POST /api/summaries rejects a body that is not JSON" 400 '.error == "bad_request"'

# The summarizer's own validation answers this one, so it proves the wiring between the two.
call POST /api/summaries '{"url":"https://example.com/wiki/Java"}'
expect "the summarizer's answer for a bad address comes through" 400 '.error == "bad_request"'

article='https://en.wikipedia.org/wiki/Java_(programming_language)'
CALL_TIMEOUT=150 call POST /api/summaries "$(jq -nc --arg url "$article" '{url:$url}')"
if [ "$code" = 503 ] && [ "$(printf '%s' "$body" | jq -r '.error // empty')" = copilot_not_authenticated ]; then
  if [ "${REQUIRE_AUTH:-0}" = 1 ]; then
    fail "the Copilot CLI is not authenticated; run 'make auth'"
  else
    pass "POST /api/summaries relays the missing-credentials answer"
    warn "live summary skipped: the Copilot CLI sidecar has no GitHub credentials (run 'make auth')"
  fi
else
  expect "POST /api/summaries summarizes a real article through the summarizer" 200 '
    (.title | length > 0) and (.summary | length > 0) and (.url | startswith("https://en.wikipedia.org/wiki/"))'
fi

smoke_result wikipedia-frontend
