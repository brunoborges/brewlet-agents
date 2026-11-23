#!/usr/bin/env bash
# Deploys the observability stack to the kind cluster, in namespace $OBSERVABILITY_NAMESPACE:
#
#   aspire-dashboard   the OpenTelemetry dashboard: it receives the OTLP that the jlib-inspector agent
#                      of the java-25-jlib runtime exports (cluster/observability/otel-dashboard.yaml)
#   jlib-server        the jlib-inspector server that the agent reports to (apps/jlib-server, java-25)
#   jlib-ui            the jlib-inspector dashboard (apps/jlib-ui, node-24)
#
#   scripts/observability.sh             build, publish and deploy all three
#   scripts/observability.sh --manifest  print the OpenTelemetry dashboard's manifest as it is applied
#                                        (the image pinned by digest) and exit; needs no cluster
#
# 'make observability' calls this script. 'make dashboards' opens the three UIs and 'make telemetry'
# checks that data arrives. An application reports to the stack when it runs on the java-25-jlib
# runtime and its Deployment sets JLIB_SERVER_URL and OTEL_EXPORTER_OTLP_ENDPOINT, as
# apps/wikipedia-summarizer does. The script is safe to re-run.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

manifest="$ROOT/cluster/observability/otel-dashboard.yaml"
image_repo="${OTEL_DASHBOARD_IMAGE%@*}"

# The manifest names the Aspire image by tag. The digest in versions.env is what runs, so a moved tag
# cannot change the dashboard.
pinned="$(awk -v repo="$image_repo" -v image="$OTEL_DASHBOARD_IMAGE" '
  $1 == "image:" && index($2, repo ":") == 1 { sub(/image:.*/, "image: " image); replaced++ }
  { print }
  END { exit (replaced == 1) ? 0 : 1 }
' "$manifest")" || die "${manifest#"$ROOT"/} must have exactly one 'image: $image_repo:<tag>' line"

if [ "${1:-}" = "--manifest" ]; then
  printf '%s\n' "$pinned"
  exit 0
fi
[ "$#" -eq 0 ] || die "usage: $(basename "$0") [--manifest]"

need docker kubectl curl openssl base64
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make cluster' first"
for runtime in java-25 node-24; do
  kube get runtimeimage "$runtime" >/dev/null 2>&1 || die "runtime $runtime is not registered: run 'make runtimes' first"
done

namespace="$OBSERVABILITY_NAMESPACE"
ensure_namespace "$namespace"

# The dashboard's login token and the key of its telemetry API are generated once. Values travel on
# stdin, never on a command line, and 'create' (unlike 'apply') leaves no last-applied annotation
# that would copy them. 'make dashboards' and 'make telemetry' read them back.
if ! kube -n "$namespace" get secret "$OTEL_DASHBOARD" >/dev/null 2>&1; then
  log "creating Secret $OTEL_DASHBOARD with a random browser token and API key"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  browser-token: %s\n  api-key: %s\n' \
    "$OTEL_DASHBOARD" "$namespace" \
    "$(openssl rand -hex 24 | tr -d '\n' | base64 | tr -d '\n')" \
    "$(openssl rand -hex 24 | tr -d '\n' | base64 | tr -d '\n')" | kube create -f - >/dev/null
fi

log "deploying the OpenTelemetry dashboard ($OTEL_DASHBOARD) to namespace $namespace"
printf '%s\n' "$pinned" | kube apply -f - >/dev/null
if ! kube -n "$namespace" rollout status "deployment/$OTEL_DASHBOARD" --timeout=5m; then
  warn "$OTEL_DASHBOARD did not become ready; recent Pod events and logs:"
  kube -n "$namespace" get events --sort-by=.lastTimestamp 2>&1 | tail -n 15 >&2 || true
  kube -n "$namespace" logs "deployment/$OTEL_DASHBOARD" --tail=40 >&2 || true
  die "$OTEL_DASHBOARD failed to roll out"
fi
ok "$OTEL_DASHBOARD is running in namespace $namespace: $OTEL_DASHBOARD_IMAGE"

# The jlib-inspector server first, then its dashboard, which reports the server's status.
for app in jlib-server jlib-ui; do
  "$ROOT/scripts/agent-build.sh" "$app"
  "$ROOT/scripts/agent-publish.sh" "$app"
  "$ROOT/scripts/agent-deploy.sh" "$app"
  "$ROOT/scripts/app-smoke.sh" "$app"
done

ok "the observability stack is running in namespace $namespace"
printf '%s\n' \
  "  open the dashboards:   make dashboards" \
  "  check that data flows: make telemetry   (an application on the java-25-jlib runtime has to run first: make wikipedia)" >&2
