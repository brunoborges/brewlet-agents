#!/usr/bin/env bash
# Talks to a deployed agent through a port-forward to its Service.
#
#   scripts/agent-ask.sh <agent> ["<question>"]     ask the model (needs 'make auth')
#   scripts/agent-ask.sh <agent> --runtime          print the live /runtime document
#
# 'make ask AGENT=<agent> Q="..."' and 'make whoami AGENT=<agent>' call this script.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl curl jq

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent> [\"<question>\" | --runtime]"
agent_dir "$agent" >/dev/null
mode="${2:-}"
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
  kill -0 "$pf_pid" 2>/dev/null || { cat "$work/pf.log" >&2; die "port-forward to $agent failed: is it deployed? (make deploy AGENT=$agent)"; }
  sleep 1
done
[ -n "$port" ] || die "port-forward to $agent did not start"
base="http://127.0.0.1:$port"

if [ "$mode" = "--runtime" ]; then
  curl -fsS -m 20 "$base/runtime" | jq .
  exit 0
fi

question="${mode:-Which language runtime, SDK and Copilot CLI version are you running on? Use your tool and answer in a few short lines.}"
payload="$(jq -n --arg q "$question" --arg c "${CONVERSATION_ID:-}" \
  'if $c == "" then {question: $q} else {question: $q, conversationId: $c} end')"

log "asking $agent: $question"
status="$(curl -sS -m 180 -o "$work/body" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d "$payload" "$base/ask")" || die "could not reach $agent"

if [ "$status" = 200 ]; then
  jq -r .answer "$work/body"
else
  printf 'HTTP %s: %s\n' "$status" "$(jq -r '"\(.error): \(.message)"' "$work/body" 2>/dev/null || head -c 300 "$work/body")" >&2
  [ "$status" != 503 ] || warn "if this is copilot_not_authenticated, run 'make auth' (docs/authentication.md)"
  exit 1
fi
