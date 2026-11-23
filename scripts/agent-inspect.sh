#!/usr/bin/env bash
# Shows how a deployed agent's or app's Pod is put together, for demos and for answering "who holds
# the token?": the runtime and the artifact its main container runs, the sidecar, and which container
# receives which environment variable. Names only: values are never printed.
#
#   scripts/agent-inspect.sh <agent-or-app>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
need kubectl jq

agent="${1:-}"
[ -n "$agent" ] || die "usage: $(basename "$0") <agent-or-app>"
agent_dir "$agent" >/dev/null
namespace="$(workload_namespace "$agent")"
container="$(workload_container "$agent")"
[ -f "$KUBECONFIG" ] || die "no cluster: run 'make up' first"

pod_json="$(kube -n "$namespace" get pods -l "app.kubernetes.io/name=$agent" -o json | jq '.items[0] // empty')"
[ -n "$pod_json" ] || die "$agent is not deployed: run 'make agent AGENT=$agent'"

# A jq query over the Pod. It may use `containers` (the init containers, which include the
# native sidecar, followed by the regular ones), $sidecar (the sidecar's container name) and
# $container (the name of the main container).
query() {
  jq -r --arg sidecar "$SIDECAR_NAME" --arg container "$container" \
    "def containers: (.spec.initContainers // []) + .spec.containers; $1" <<<"$pod_json"
}

runtime="$(query '.metadata.annotations["runtime-image.brewlet.sh/" + $container] // empty')"
runtime_status=""
if [ -n "$runtime" ]; then
  generation="$(kube get runtimeimage "$runtime" -o jsonpath='{.status.generation}' 2>/dev/null || true)"
  digest="$(kube get runtimeimage "$runtime" -o jsonpath='{.status.digest}' 2>/dev/null || true)"
  runtime_status="  (generation ${generation:-?}, image ${digest:0:19})"
fi

log "$agent: Pod $(query .metadata.name) on node $(query .spec.nodeName)"
printf '  %-17s %s\n' runtimeClassName "$(query '.spec.runtimeClassName // "-"')"
printf '  %-17s %s\n' "runtime (Ops)" "${runtime:--}$runtime_status"
printf '  %-17s %s\n' "artifact (dev)" "$(query '.metadata.annotations["brewlet.sh/artifact-ref"] // "-"')"
printf '  %-17s %s\n' sidecar "$(query '[containers[] | select(.name == $sidecar) | .image][0] // "-"')"
echo "  environment variables, by container (names only):"
while IFS=$'\t' read -r name vars; do
  printf '    %-12s %s\n' "$name" "$vars"
done < <(query 'containers[] | "\(.name)\t\([.env[]?.name] | join(" "))"')

holders="$(query '[containers[] | select([.env[]?.name] | index("COPILOT_GITHUB_TOKEN")) | .name] | join(", ")')"
echo
ok "the GitHub token (COPILOT_GITHUB_TOKEN) is injected into: ${holders:-no container}"
