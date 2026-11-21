#!/usr/bin/env bash
# Prints the manifest of one agent on stdout: the ServiceAccount, Deployment and Service from
# deploy/agent.yaml.tmpl with the agent's settings filled in.
#
#   scripts/agent-render.sh <agent> <artifact-ref> <sidecar-ref>
#
# scripts/agent-deploy.sh applies the result. scripts/check.sh renders every agent with
# placeholder references, so a broken agent.env fails in CI without a cluster.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ "$#" -eq 3 ] || die "usage: $(basename "$0") <agent> <artifact-ref> <sidecar-ref>"
agent="$1" artifact="$2" sidecar="$3"
dir="$(agent_dir "$agent")"

runtime="$(env_value "$dir/agent.env" RUNTIME)"
language="$(env_value "$dir/agent.env" LANGUAGE)"
port="$(env_value "$dir/agent.env" PORT)"
cpu_request="$(env_value "$dir/agent.env" CPU_REQUEST)"
memory_request="$(env_value "$dir/agent.env" MEMORY_REQUEST)"
memory_limit="$(env_value "$dir/agent.env" MEMORY_LIMIT)"
arch="${ARCH:-$(host_arch)}"

sed \
  -e "s|@@AGENT@@|$agent|g" \
  -e "s|@@NAMESPACE@@|$AGENT_NAMESPACE|g" \
  -e "s|@@SECRET@@|$AGENT_SECRET|g" \
  -e "s|@@LANGUAGE@@|$language|g" \
  -e "s|@@RUNTIME@@|$runtime|g" \
  -e "s|@@ARCH@@|$arch|g" \
  -e "s|@@ARTIFACT@@|$artifact|g" \
  -e "s|@@PORT@@|${port:-8080}|g" \
  -e "s|@@SIDECAR@@|$sidecar|g" \
  -e "s|@@SIDECAR_PORT@@|$SIDECAR_PORT|g" \
  -e "s|@@SIDECAR_MEMORY_REQUEST@@|${SIDECAR_MEMORY_REQUEST:-128Mi}|g" \
  -e "s|@@SIDECAR_MEMORY_LIMIT@@|${SIDECAR_MEMORY_LIMIT:-512Mi}|g" \
  -e "s|@@CPU_REQUEST@@|${cpu_request:-100m}|g" \
  -e "s|@@MEMORY_REQUEST@@|${memory_request:-192Mi}|g" \
  -e "s|@@MEMORY_LIMIT@@|${memory_limit:-512Mi}|g" \
  "$ROOT/deploy/agent.yaml.tmpl"
