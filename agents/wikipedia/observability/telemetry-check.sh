#!/usr/bin/env bash
# Shows that telemetry from the applications reached both observability back ends, by reading it back
# from each of them. An environment variable or an available collector proves nothing about export.
#
#   agents/wikipedia/observability/telemetry-check.sh
#
#   1. jlib-server:       the applications that reported, with the number of jars each one loaded
#   2. aspire-dashboard:  the resources that exported OTLP, with the number of package.info log
#                         events (one per jar) that arrived from each
#   3. aspire-dashboard:  the resources that also exported traces and metrics: the applications
#                         instrument themselves for those (the summarizer does, through Spring
#                         Boot's OpenTelemetry starter), the runtime's agent only sends log events
#
# The jlib-inspector agent in the java-25-jlib runtime reports when the JVM starts and then at an
# interval (30 seconds), and the summarizer publishes its metrics every 30 seconds, so a check right
# after 'make wikipedia' polls for up to $TELEMETRY_TIMEOUT seconds (90 by default). The script fails
# if a back end has nothing by then. Traces need a request: the smoke test of 'make wikipedia' sends
# some, and the Kubernetes probes are not traced.
# 'make telemetry' calls it.
set -euo pipefail
source "$(dirname "$0")/../../../scripts/lib/common.sh"
need kubectl curl jq
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"

timeout="${TELEMETRY_TIMEOUT:-90}"
namespace="$OBSERVABILITY_NAMESPACE"
trap forward_stop EXIT

# Polls a command until it succeeds or the timeout is over.
wait_for() {
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 3
  done
}

# --- 1. the jlib-inspector server --------------------------------------------------------------------
# Through the API server's service proxy, like agent_runtime in scripts/lib/common.sh: nothing to port-forward.
apps=""
server_has_apps() {
  apps="$(kube get --raw "/api/v1/namespaces/$namespace/services/jlib-server:8080/proxy/api/apps" 2>/dev/null)" \
    && printf '%s' "$apps" | jq -e '(.applications | length) > 0' >/dev/null 2>&1
}

log "applications that reported to jlib-server"
wait_for server_has_apps \
  || die "no application has reported to jlib-server: does one run on the java-25-jlib runtime with JLIB_SERVER_URL set? ('make wikipedia' deploys one)"
printf '%s' "$apps" | jq -r '.applications[]
  | "  \(.appId[0:12])  \(.jarCount) jars  \(.jdkVendor) \(.jdkVersion)  \(if .name == "" then "(unnamed)" else .name end)  \(.commandLine | .[0:70])"' >&2

# --- 2. the OpenTelemetry dashboard ------------------------------------------------------------------
# Its telemetry API answers to the key that agents/wikipedia/observability/deploy.sh generated, which goes to curl on
# stdin (-H @-) and so never appears in a process list.
forward_start "$namespace" "$OTEL_DASHBOARD" 18888
base="http://127.0.0.1:$FORWARD_PORT"
key="$(kube -n "$namespace" get secret "$OTEL_DASHBOARD" -o go-template='{{index .data "api-key" | base64decode}}')" \
  || die "Secret $OTEL_DASHBOARD is missing: run 'make observability' first"
[ -n "$key" ] || die "Secret $OTEL_DASHBOARD has no api-key"
aspire() { printf 'x-api-key: %s\n' "$key" | curl -fsS -m 20 -H @- "$base$1"; }

# Names and event counts of the resources that exported at least one package.info event.
exports=""
aspire_has_exports() {
  local resources name events
  resources="$(aspire /api/telemetry/resources 2>/dev/null)" || return 1
  exports=""
  for name in $(printf '%s' "$resources" | jq -r '.[] | select(.hasLogs) | .name'); do
    events="$(aspire "/api/telemetry/logs?limit=10000&resource=$(jq -rn --arg n "$name" '$n | @uri')" 2>/dev/null \
      | jq '[.data.resourceLogs[].scopeLogs[].logRecords[] | select(.eventName == "package.info")] | length' 2>/dev/null)" || continue
    [ "${events:-0}" -gt 0 ] && exports="$exports  $name: $events package.info events"$'\n'
  done
  [ -n "$exports" ]
}

log "resources that exported OTLP to $OTEL_DASHBOARD"
wait_for aspire_has_exports \
  || die "no package.info event reached $OTEL_DASHBOARD: is OTEL_EXPORTER_OTLP_ENDPOINT of the application http://$OTEL_DASHBOARD.$namespace.svc:18890?"
printf '%s' "$exports" >&2

# --- 3. traces and metrics ---------------------------------------------------------------------------
signals=""
aspire_has_traces_and_metrics() {
  signals="$(aspire /api/telemetry/resources 2>/dev/null \
    | jq -r '.[] | select(.hasTraces and .hasMetrics) | "  \(.name): traces and metrics"' 2>/dev/null)" || return 1
  [ -n "$signals" ]
}

log "resources that also exported traces and metrics to $OTEL_DASHBOARD"
wait_for aspire_has_traces_and_metrics \
  || die "no resource exported both traces and metrics to $OTEL_DASHBOARD: has the application received a request ('make summarize URL=...')? Is OTEL_TRACES_EXPORTER or OTEL_METRICS_EXPORTER set to none?"
printf '%s\n' "$signals" >&2

ok "telemetry flows: the applications reported to jlib-server and exported logs, traces and metrics to $OTEL_DASHBOARD"
