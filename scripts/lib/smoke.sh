#!/usr/bin/env bash
# HTTP checks shared by scripts/workloads/smoke.sh, scripts/workloads/app-smoke.sh and apps/*/smoke.sh. Source it
# after scripts/lib/common.sh:
#
#   base=http://127.0.0.1:8080
#   call GET /healthz
#   expect "GET /healthz is UP" 200 '.status == "UP"'
#   smoke_result my-app
#
# It needs curl and jq, and $base set to the URL under test.
failures=0
code=""      # HTTP status of the last call: 000 when no answer came
body=""      # its body
curl_err=""  # what curl said when there was no answer

pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; failures=$((failures + 1)); }

# call METHOD PATH [JSON]: leaves the HTTP status in $code and the body in $body.
call() {
  local method="$1" path="$2" data="${3:-}" out err
  local args=(-sS -m "${CALL_TIMEOUT:-20}" -w '\n%{http_code}' -X "$method")
  [ -z "$data" ] || args+=(-H 'Content-Type: application/json' -d "$data")
  err="$(mktemp)"
  out="$(curl "${args[@]}" "$base$path" 2>"$err")" || out=$'\n000'
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  curl_err="$(cat "$err")"
  rm -f "$err"
}

# expect LABEL STATUS [JQ-FILTER]: the last call must have returned STATUS and, if a filter is given,
# a JSON body for which the filter is true.
expect() {
  local label="$1" want="$2" filter="${3:-}"
  if [ "$code" != "$want" ]; then
    fail "$label: HTTP $code (wanted $want) ${body:0:300} $curl_err"
  elif [ -n "$filter" ] && ! printf '%s' "$body" | jq -e "$filter" >/dev/null 2>&1; then
    fail "$label: unexpected body ${body:0:300}"
  else
    pass "$label"
  fi
}

# any_failed: succeeds if a check has failed so far.
any_failed() { [ "$failures" -gt 0 ]; }

# smoke_result NAME: ends the script, with an error if any check failed.
smoke_result() {
  [ "$failures" -eq 0 ] || die "$1: $failures check(s) failed"
  ok "$1 passed the smoke test"
}
