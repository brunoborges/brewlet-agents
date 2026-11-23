#!/usr/bin/env bash
# The wikipedia-summarizer's own checks, run by scripts/workloads/app-smoke.sh against the deployed Service. They
# also work by hand against any instance:
#
#   apps/wikipedia-summarizer/smoke.sh http://localhost:8080
#
# Everything up to the last check needs neither the Copilot CLI's credentials nor a model. The last
# one summarizes a real article; without credentials it expects the documented 503, unless
# REQUIRE_AUTH=1 makes the credentials mandatory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/smoke.sh"
need curl jq

base="${1:-}"
[ -n "$base" ] || die "usage: $(basename "$0") <base-url>"

call GET /readyz
expect "GET /readyz is READY (the app reached the Copilot CLI sidecar)" 200 '.status == "READY"'

# The address is validated before anything is fetched, so none of these reach Wikipedia.
for bad in \
  '{}' \
  '{"url":""}' \
  '{"url":"https://example.com/wiki/Java"}' \
  '{"url":"http://en.wikipedia.org/wiki/Java"}' \
  '{"url":"https://en.wikipedia.org.example.com/wiki/Java"}' \
  '{"url":"https://user:secret@en.wikipedia.org/wiki/Java"}' \
  '{"url":"https://en.wikipedia.org/w/index.php?title=Java"}'; do
  call POST /api/summaries "$bad"
  expect "POST /api/summaries rejects $bad" 400 '.error == "bad_request"'
done

call POST /api/summaries '{"url":"https://en.wikipedia.org/wiki/No_such_article_brewlet_agents_9f3a1c"}'
expect "a missing article is reported as 404 article_not_found" 404 '.error == "article_not_found"'

article='https://en.wikipedia.org/wiki/Java_(programming_language)'
CALL_TIMEOUT=150 call POST /api/summaries "$(jq -nc --arg url "$article" '{url:$url}')"
if [ "$code" = 503 ] && [ "$(printf '%s' "$body" | jq -r '.error // empty')" = copilot_not_authenticated ]; then
  if [ "${REQUIRE_AUTH:-0}" = 1 ]; then
    fail "the Copilot CLI is not authenticated; run 'make auth'"
  else
    pass "POST /api/summaries reports missing credentials instead of hanging"
    warn "live summary skipped: the Copilot CLI sidecar has no GitHub credentials (run 'make auth')"
  fi
else
  expect "POST /api/summaries summarizes a real article" 200 '
    (.title | length > 0) and (.summary | length > 0) and (.url | startswith("https://en.wikipedia.org/wiki/"))
    and (.truncated | type == "boolean")'
  [ "$code" != 200 ] || printf '    \033[2m%s\033[0m\n' "$(printf '%s' "$body" | jq -r .summary | head -c 400)"
fi

smoke_result wikipedia-summarizer
