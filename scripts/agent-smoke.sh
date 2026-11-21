#!/usr/bin/env bash
# Black-box check of a deployed agent through a port-forward to its Service.
#
#   scripts/agent-smoke.sh <agent>
#
# It verifies the Runtime Concierge contract (agents/README.md) and prints the proof that matters
# for the demo: the app lives under /app, the language runtime lives somewhere else, and the Copilot
# CLI is a separate attached sidecar. A live model round trip needs credentials ('make auth'); set
# REQUIRE_AUTH=1 to make that mandatory instead of optional.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl curl jq

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent>"
dir="$(agent_dir "$agent")"
runtime="$(env_value "$dir/agent.env" RUNTIME)"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

work="$(mktemp -d)"
pf_pid=""
cleanup() {
  if [ -n "$pf_pid" ]; then
    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# kubectl is started directly (not through the kube() function) so $! is its own PID.
kubectl --kubeconfig "$KUBECONFIG" --context "kind-${CLUSTER_NAME}" -n "$AGENT_NAMESPACE" \
  port-forward "svc/$agent" :80 >"$work/pf.log" 2>&1 &
pf_pid=$!

port=""
for _ in $(seq 1 30); do
  port="$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\) -> .*/\1/p' "$work/pf.log" | head -n1)"
  [ -z "$port" ] || break
  kill -0 "$pf_pid" 2>/dev/null || { cat "$work/pf.log" >&2; die "port-forward to $agent failed"; }
  sleep 1
done
[ -n "$port" ] || die "port-forward to $agent did not start"
base="http://127.0.0.1:$port"

failures=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; failures=$((failures + 1)); }

# call METHOD PATH [JSON]: leaves the HTTP status in $code and the body in $work/body.
code=""
call() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -m "${CALL_TIMEOUT:-20}" -o "$work/body" -w '%{http_code}' -X "$method")
  [ -z "$data" ] || args+=(-H 'Content-Type: application/json' -d "$data")
  code="$(curl "${args[@]}" "$base$path" 2>"$work/curl.err")" || { code=000; : > "$work/body"; }
}

# expect LABEL STATUS [JQ-FILTER]: the last call must return STATUS and, if given, a JSON body
# for which the filter is true.
expect() {
  local label="$1" want="$2" filter="${3:-}"
  if [ "$code" != "$want" ]; then
    fail "$label: HTTP $code (wanted $want) $(head -c 300 "$work/body") $(cat "$work/curl.err")"
  elif [ -n "$filter" ] && ! jq -e "$filter" "$work/body" >/dev/null 2>&1; then
    fail "$label: unexpected body $(head -c 300 "$work/body")"
  else
    pass "$label"
  fi
}

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
cp "$work/body" "$work/runtime.json"
expect "the language runtime is not part of the app artifact" 200 '(.language.home | startswith("/app") | not)'
expect "no GitHub identity is exposed" 200 'tostring | test("login|ghp_|gho_|github_pat_") | not'

call POST /ask '{"question":""}'
expect "POST /ask rejects an empty question" 400 '.error == "bad_request"'

call POST /ask '{"question":"hi","conversationId":"has spaces!"}'
expect "POST /ask rejects a malformed conversationId" 400 '.error == "bad_request"'

authenticated="$(jq -r '.copilot.cli.authenticated // false' "$work/runtime.json")"
if [ "$authenticated" = "true" ]; then
  CALL_TIMEOUT=150 call POST /ask '{"question":"Which language runtime and which Copilot CLI version are you running on? Use your tool. Answer in two short sentences."}'
  expect "POST /ask returns a model answer" 200 '(.answer | length > 0) and (.conversationId | length > 0)'
  [ "$code" != 200 ] || printf '    \033[2m%s\033[0m\n' "$(jq -r .answer "$work/body" | head -c 400)"
  # Excluding the CLI's built-in tools is not enough: its GitHub MCP tools and web_search stay
  # callable. The agents allow-list only their own tool, and the model itself is the witness.
  CALL_TIMEOUT=150 call POST /ask '{"question":"List the exact names of every tool you are able to call right now, one per line. Do not call any of them. Do not explain."}'
  expect "the model can call only the agent's own tool (runtime_facts)" 200 '
    .answer | contains("runtime_facts")
    and (test("github-mcp-server|web_search|\\bbash\\b|\\bpowershell\\b|\\bweb_fetch\\b") | not)'
elif [ "${REQUIRE_AUTH:-0}" = "1" ]; then
  fail "the Copilot CLI is not authenticated; run 'make auth'"
else
  call POST /ask '{"question":"hello"}'
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
' "$work/runtime.json" >&2

[ "$failures" -eq 0 ] || die "$agent: $failures check(s) failed"
ok "$agent passed the smoke test"
