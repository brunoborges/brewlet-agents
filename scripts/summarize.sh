#!/usr/bin/env bash
# Summarizes a Wikipedia article through the REST API of the deployed wikipedia-summarizer.
#
#   scripts/summarize.sh <wikipedia-article-url>
#   scripts/summarize.sh --frontend <wikipedia-article-url>   the same request through the Node.js front-end
#   scripts/summarize.sh --json <wikipedia-article-url>       print the raw JSON response
#
# 'make summarize URL=...' calls this script. The model call needs GitHub credentials in the cluster
# ('make auth').
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl curl jq

service=wikipedia-summarizer
raw=0
while [ "$#" -gt 1 ]; do
  case "$1" in
    --frontend) service=wikipedia-frontend ;;
    --json) raw=1 ;;
    *) break ;;
  esac
  shift
done
url="${1:-}"
[ "$#" -eq 1 ] && [ -n "$url" ] || die "usage: $(basename "$0") [--frontend] [--json] <wikipedia-article-url>"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

work="$(mktemp -d)"
cleanup() { forward_stop; rm -rf "$work"; }
trap cleanup EXIT

forward_start "$AGENT_NAMESPACE" "$service" 80

log "summarizing $url through $service"
status="$(curl -sS -m 200 -o "$work/body" -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d "$(jq -n --arg url "$url" '{url: $url}')" \
  "http://127.0.0.1:$FORWARD_PORT/api/summaries")" || die "could not reach $service"

if [ "$status" != 200 ]; then
  printf 'HTTP %s: %s\n' "$status" "$(jq -r '"\(.error): \(.message)"' "$work/body" 2>/dev/null || head -c 300 "$work/body")" >&2
  [ "$(jq -r .error "$work/body" 2>/dev/null)" != copilot_not_authenticated ] \
    || warn "the Copilot CLI has no GitHub credentials: run 'make auth' (docs/authentication.md)"
  exit 1
fi

if [ "$raw" = 1 ]; then
  jq . "$work/body"
else
  jq -r '"\(.title)  <\(.url)>\n\n\(.summary)" + (if .truncated then "\n\n(only the beginning of a long article was summarized)" else "" end)' "$work/body"
fi
