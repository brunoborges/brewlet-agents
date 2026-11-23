#!/usr/bin/env bash
# Black-box check of a deployed agent through a port-forward to its Service.
#
#   scripts/workloads/smoke.sh <agent>
#
# An app (apps/<name>) has no such contract, so this hands it to scripts/workloads/app-smoke.sh.
#
# It verifies the Runtime Concierge contract (agents/README.md) and prints the proof that matters
# for the demo: the app lives under /app, the language runtime lives somewhere else, and the Copilot
# CLI is a separate attached sidecar. A live model round trip needs credentials ('make auth'); set
# REQUIRE_AUTH=1 to make that mandatory instead of optional.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/smoke.sh"
need kubectl curl jq

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent-or-app>"
# Apps have no Runtime Concierge contract to check; they bring their own checks.
[ "$(workload_kind "$agent")" = agents ] || exec "$(dirname "$0")/app-smoke.sh" "$agent"
dir="$(agent_dir "$agent")"
runtime="$(env_value "$dir/agent.env" RUNTIME)"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

trap forward_stop EXIT
forward_start "$AGENT_NAMESPACE" "$agent" 80
base="http://127.0.0.1:$FORWARD_PORT"

log "smoke-testing $agent (runtime $runtime) at $base"

call GET /healthz
expect "GET /healthz is UP" 200 '.status == "UP"'

call GET /readyz
expect "GET /readyz is READY (the app reached the Copilot CLI sidecar)" 200 '.status == "READY"'

call GET /runtime
expect "GET /runtime has the contract shape" 200 "
  (.agent.name == \"$agent\") and (.agent.framework.name | length > 0) and (.agent.location | startswith(\"/app\"))
  and (.language.name | length > 0) and (.language.version | length > 0)
  and (.copilot.sdk.version | length > 0) and (.copilot.integration.version | length > 0)
  and (.copilot.cli.attached == true) and (.copilot.cli.version | length > 0)
  and (.deployment.runtimeId == \"$runtime\") and (.deployment.pod | length > 0)"
runtime_json="$body"
expect "the language runtime is not part of the app artifact" 200 '(.language.home | startswith("/app") | not)'
expect "no GitHub identity is exposed" 200 'tostring | test("login|ghp_|gho_|github_pat_") | not'

call POST /ask '{"question":""}'
expect "POST /ask rejects an empty question" 400 '.error == "bad_request"'

call POST /ask '{"question":"hi","conversationId":"has spaces!"}'
expect "POST /ask rejects a malformed conversationId" 400 '.error == "bad_request"'

# repeat N: N times the letter a.
repeat() { printf '%*s' "$1" '' | tr ' ' a; }
call POST /ask "$(jq -nc --arg id "$(repeat 129)" '{question:"hi",conversationId:$id}')"
expect "POST /ask rejects a conversationId longer than 128 characters" 400 '.error == "bad_request"'
call POST /ask "$(jq -nc --arg q "$(repeat 4001)" '{question:$q}')"
expect "POST /ask rejects a question longer than 4000 characters" 400 '.error == "bad_request"'

# Every character the contract allows in a conversationId, including the ones a Copilot session id
# cannot contain: the agent maps the id to a session id the sidecar accepts.
awkward_id='smoke.test:1/a-b_c'

authenticated="$(printf '%s' "$runtime_json" | jq -r '.copilot.cli.authenticated // false')"
if [ "$authenticated" = "true" ]; then
  CALL_TIMEOUT=150 call POST /ask "$(jq -nc --arg id "$awkward_id" '{question:"Reply with the single word OK.",conversationId:$id}')"
  expect "POST /ask accepts every character the contract allows in a conversationId" 200 ".conversationId == \"$awkward_id\""
  CALL_TIMEOUT=150 call POST /ask '{"question":"Which language runtime and which Copilot CLI version are you running on? Use your tool. Answer in two short sentences."}'
  expect "POST /ask returns a model answer" 200 '(.answer | length > 0) and (.conversationId | length > 0)'
  [ "$code" != 200 ] || printf '    \033[2m%s\033[0m\n' "$(printf '%s' "$body" | jq -r .answer | head -c 400)"
  # Excluding the CLI's built-in tools is not enough: its GitHub MCP tools and web_search stay
  # callable. The agents allow-list only their own tool, and the model itself is the witness.
  CALL_TIMEOUT=150 call POST /ask '{"question":"List the exact names of every tool you are able to call right now, one per line. Do not call any of them. Do not explain."}'
  expect "the model can call only the agent's own tool (runtime_facts)" 200 '
    .answer | contains("runtime_facts")
    and (test("github-mcp-server|web_search|\\bbash\\b|\\bpowershell\\b|\\bweb_fetch\\b") | not)'
elif [ "${REQUIRE_AUTH:-0}" = "1" ]; then
  fail "the Copilot CLI is not authenticated; run 'make auth'"
else
  call POST /ask "$(jq -nc --arg id "$awkward_id" '{question:"hello",conversationId:$id}')"
  expect "POST /ask reports missing credentials instead of hanging" 503 '.error == "copilot_not_authenticated"'
  warn "live /ask skipped: the Copilot CLI sidecar has no GitHub credentials (run 'make auth')"
fi

echo
jq -r '
  "  agent      \(.agent.name)  [\(.agent.framework.name) \(.agent.framework.version // "")]  \(.agent.location)",
  "  language   \(.language.name) \(.language.version)  (\(.language.vendor // "n/a"))  \(.language.home // "")",
  "  sdk        \(.copilot.sdk.name // "copilot-sdk") \(.copilot.sdk.version)  integration \(.copilot.integration.name // "") \(.copilot.integration.version)",
  "  cli        \(.copilot.cli.endpoint)  version \(.copilot.cli.version)  authenticated=\(.copilot.cli.authenticated)",
  "  deployment runtime=\(.deployment.runtimeId)  pod=\(.deployment.pod)  node=\(.deployment.node)"
' <<<"$runtime_json" >&2

smoke_result "$agent"
