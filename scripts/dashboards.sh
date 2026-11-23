#!/usr/bin/env bash
# Opens the dashboards of the local platform on fixed localhost ports, through port-forwards, until
# Ctrl-C:
#
#   brewlet    http://127.0.0.1:8088    Brewlet: the runtimes, the node profiles and the workloads on them
#   jlib       http://127.0.0.1:3000    jlib-inspector: the libraries each application really loaded
#   otel       http://127.0.0.1:18888   OpenTelemetry (Aspire): the OTLP the jlib-inspector agents export
#   frontend   http://127.0.0.1:8080    the Wikipedia summarizer's Node.js front-end
#
#   scripts/dashboards.sh                       every dashboard that is deployed
#   scripts/dashboards.sh jlib otel             only these
#   scripts/dashboards.sh --check [name...]     open them, request each page once, close them again
#
# 'make dashboards' calls this script. The ports are fixed because the jlib dashboard's page connects
# to ws://localhost:3001 on its own (it needs 3000 and 3001 at the same numbers locally).
#
# What signs you in: Brewlet takes a short-lived Kubernetes token, which this script mints for a
# read-only ServiceAccount (runtime-reader, bound to the chart's brewlet-dashboard-viewer role) and
# prints; the OpenTelemetry dashboard takes the token in the login link that is printed. The jlib
# dashboard and the front-end have no sign-in at all: they are reachable only from this machine,
# through the port-forward, and are not meant for anything else.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/smoke-lib.sh"
need kubectl curl jq

check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
wanted="$*"
for name in $wanted; do
  case "$name" in brewlet|jlib|otel|frontend) ;; *) die "unknown dashboard '$name': one of brewlet, jlib, otel, frontend" ;; esac
done
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

# target NAME: the namespace, the Service and the local:remote ports of a dashboard.
target() {
  case "$1" in
    brewlet)  echo "brewlet brewlet-dashboard 8088:8088" ;;
    jlib)     echo "$(workload_namespace jlib-ui) jlib-ui 3000:3000 3001:3001" ;;
    otel)     echo "$OBSERVABILITY_NAMESPACE $OTEL_DASHBOARD 18888:18888" ;;
    frontend) echo "$(workload_namespace wikipedia-frontend) wikipedia-frontend 8080:80" ;;
  esac
}

# deployed_by NAME: the command that deploys a dashboard.
deployed_by() {
  case "$1" in
    brewlet)    echo "make cluster" ;;
    jlib|otel)  echo "make observability" ;;
    frontend)   echo "make wikipedia" ;;
  esac
}

forwards=""   # "<pid>:<name>" of each running port-forward
stop_forwards() {
  local f
  for f in $forwards; do kill "${f%%:*}" 2>/dev/null || true; done
  for f in $forwards; do wait "${f%%:*}" 2>/dev/null || true; done
  forwards=""
}
trap stop_forwards EXIT
trap 'exit 130' INT TERM

# start_forward NAME: port-forwards the dashboard's Service and waits until every local port listens.
start_forward() {
  local name="$1" namespace service out pid spec port _ ready
  # shellcheck disable=SC2046 # the target is a list of words
  set -- $(target "$name")
  namespace="$1" service="$2"; shift 2
  out="$(mktemp)"
  kubectl --kubeconfig "$KUBECONFIG" --context "kind-${CLUSTER_NAME}" -n "$namespace" \
    port-forward "svc/$service" "$@" >"$out" 2>&1 &
  pid=$!
  forwards="$forwards $pid:$name"
  for _ in $(seq 1 30); do
    ready=1
    for spec in "$@"; do
      port="${spec%%:*}"
      grep -q "Forwarding from 127.0.0.1:$port " "$out" || ready=0
    done
    [ "$ready" -eq 0 ] || { rm -f "$out"; return 0; }
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  cat "$out" >&2
  rm -f "$out"
  die "port-forward to $namespace/$service ($*) failed: is one of those ports already in use on this machine?"
}

# Which dashboards: the ones asked for, or else the ones that are deployed.
names=""
for name in ${wanted:-brewlet jlib otel frontend}; do
  # shellcheck disable=SC2046 # the target is a list of words
  set -- $(target "$name")
  if kube -n "$1" get service "$2" >/dev/null 2>&1; then
    names="$names $name"
  elif [ -n "$wanted" ]; then
    die "$name is not deployed: run '$(deployed_by "$name")' first"
  else
    warn "skipping $name: it is not deployed ('$(deployed_by "$name")')"
  fi
done
[ -n "$names" ] || die "no dashboard is deployed"

# Brewlet signs in with a bearer token of an identity that may read the runtimes: a dedicated,
# read-only ServiceAccount, as the Brewlet dashboard documentation describes. The token is minted
# on every run and expires; none is stored.
brewlet_token=""
if [[ " $names " == *" brewlet "* ]]; then
  kube -n brewlet get serviceaccount runtime-reader >/dev/null 2>&1 \
    || kube -n brewlet create serviceaccount runtime-reader >/dev/null
  kube get clusterrolebinding runtime-reader-view >/dev/null 2>&1 \
    || kube create clusterrolebinding runtime-reader-view \
         --clusterrole=brewlet-dashboard-viewer --serviceaccount=brewlet:runtime-reader >/dev/null
  brewlet_token="$(kube -n brewlet create token runtime-reader --duration=1h)"
fi
otel_token=""
if [[ " $names " == *" otel "* ]]; then
  otel_token="$(kube -n "$OBSERVABILITY_NAMESPACE" get secret "$OTEL_DASHBOARD" \
    -o go-template='{{index .data "browser-token" | base64decode}}')" \
    || die "Secret $OTEL_DASHBOARD is missing: run 'make observability' first"
fi

for name in $names; do start_forward "$name"; done

if [ "$check" -eq 1 ]; then
  for name in $names; do
    case "$name" in
      brewlet)
        base="http://127.0.0.1:8088"
        call GET /healthz;  expect "Brewlet dashboard: GET /healthz answers 200" 200
        call GET /;         expect "Brewlet dashboard: GET / serves the page" 200
        # The sign-in is a bearer token; the header goes to curl on stdin, not on its command line.
        status="$(printf 'Authorization: Bearer %s\n' "$brewlet_token" \
          | curl -sS -m 20 -H @- -o "${TMPDIR:-/tmp}/brewlet-snapshot.$$" -w '%{http_code}' "$base/api/snapshot" 2>/dev/null)" || status=000
        if [ "$status" = 200 ] && jq -e '(.runtimes | length) > 0 and (.errors == {})' "${TMPDIR:-/tmp}/brewlet-snapshot.$$" >/dev/null 2>&1; then
          pass "Brewlet dashboard: the minted token signs in and lists $(jq '.runtimes | length' "${TMPDIR:-/tmp}/brewlet-snapshot.$$") runtimes and $(jq '.pods | length' "${TMPDIR:-/tmp}/brewlet-snapshot.$$") Pods"
        else
          fail "Brewlet dashboard: GET /api/snapshot with the minted token: HTTP $status"
        fi
        rm -f "${TMPDIR:-/tmp}/brewlet-snapshot.$$"
        ;;
      jlib)
        base="http://127.0.0.1:3000"
        call GET /api/health; expect "jlib dashboard: reaches the jlib-inspector server" 200 '.jlibServerStatus == "connected"'
        call GET /;           expect "jlib dashboard: GET / serves the page" 200
        # The page's live updates: an HTTP upgrade to a WebSocket on port 3001 must answer 101.
        handshake="$(curl -sS -i -N -m 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
          -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://127.0.0.1:3001/ 2>/dev/null | head -n 1 || true)"
        case "$handshake" in
          *' 101 '*) pass "jlib dashboard: the WebSocket on port 3001 upgrades" ;;
          *) fail "jlib dashboard: the WebSocket on port 3001 answered '${handshake:-nothing}'" ;;
        esac
        ;;
      otel)
        base="http://127.0.0.1:18888"
        call GET /login; expect "OpenTelemetry dashboard: GET /login answers 200" 200
        jar="$(mktemp)"
        landed="$(printf '%s' "$otel_token" | curl -sS -m 20 -o /dev/null -c "$jar" -b "$jar" -L -w '%{url_effective}' \
          "$base/login?t=$(cat)" 2>/dev/null)" || landed=""
        rm -f "$jar"
        case "$landed" in
          ''|*/login*) fail "OpenTelemetry dashboard: the browser token does not sign in (landed on '${landed:-nothing}')" ;;
          *) pass "OpenTelemetry dashboard: the browser token signs in" ;;
        esac
        ;;
      frontend)
        base="http://127.0.0.1:8080"
        call GET /; expect "front-end: GET / serves the page" 200
        ;;
    esac
  done
  if any_failed; then die "a dashboard did not answer as expected (see ✗ above)"; fi
  ok "the dashboards answer: ${names# }"
  exit 0
fi

echo
for name in $names; do
  case "$name" in
    brewlet)
      echo "Brewlet dashboard         http://127.0.0.1:8088"
      echo "  Paste this token into the sign-in form; it is valid for one hour:"
      echo "  $brewlet_token"
      ;;
    jlib)
      echo "jlib-inspector dashboard  http://127.0.0.1:3000   (it also needs port 3001, for live updates)"
      ;;
    otel)
      echo "OpenTelemetry dashboard   http://127.0.0.1:18888/login?t=$otel_token"
      ;;
    frontend)
      echo "Wikipedia front-end       http://127.0.0.1:8080"
      ;;
  esac
done
echo
log "forwarding until you press Ctrl-C"

# A port-forward ends when its Pod does: say so, rather than leave a dead link on the screen.
while :; do
  sleep 2
  for f in $forwards; do
    kill -0 "${f%%:*}" 2>/dev/null || die "the port-forward to ${f#*:} ended (did its Pod restart?): run this again"
  done
done
