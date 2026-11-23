#!/usr/bin/env bash
# The Ops half of the story, live: patch the Java runtime once and every Java agent moves to the
# new JDK without being rebuilt, re-pushed or re-deployed.
#
#   scripts/demos/rotation.sh [status|previous|current|all]
#
#   status     show the JDK every Java agent runs on, next to the artifact it runs
#   previous   rewind java-25 to an older Microsoft Build of OpenJDK ("last quarter's runtime")
#   current    rotate java-25 to the approved image in runtimes/java-25.env ("patch day")
#   all        previous, then current. The default, and what 'make rotate' runs.
#
# Only the RuntimeImage changes. The artifact digest printed beside every agent never does.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
need docker kubectl brewlet curl jq

RUNTIME_ID=java-25
APPROVED_IMAGE="$(env_value "$ROOT/runtimes/$RUNTIME_ID.env" IMAGE)"
PREVIOUS_REPO="runtimes/$RUNTIME_ID"
PREVIOUS_IMAGE="$REGISTRY_HOST/$PREVIOUS_REPO:$ROTATION_JDK_VERSION"

[ -f "$KUBECONFIG" ] || die "no cluster: run 'make up' first"
kube get runtimeimage "$RUNTIME_ID" >/dev/null 2>&1 \
  || die "runtime $RUNTIME_ID is not approved in the cluster: run 'make up' first"

# One Deployment name per line: every agent whose Pods run on the runtime.
agents_on_runtime() {
  kube -n "$AGENT_NAMESPACE" get deployments -o json | jq -r --arg rt "$RUNTIME_ID" '
    .items[]
    | select(.spec.template.metadata.annotations["runtime-image.brewlet.sh/agent"] == $rt)
    | .metadata.name'
}

# "<deployment> <metadata.generation>" per line; a changed pod template bumps the generation.
deployment_generations() {
  kube -n "$AGENT_NAMESPACE" get deployments -o json | jq -r --arg rt "$RUNTIME_ID" '
    .items[]
    | select(.spec.template.metadata.annotations["runtime-image.brewlet.sh/agent"] == $rt)
    | "\(.metadata.name) \(.metadata.generation)"'
}

current_digest() { kube get runtimeimage "$RUNTIME_ID" -o jsonpath='{.status.digest}'; }

# The runtime generations an agent's Pods run on, as Brewlet's operator records them: "1,2" while a
# rollout is in flight, "2" once it is over. Empty when the operator has not seen the agent.
workload_generations() { # AGENT RUNTIME_JSON
  jq -r --arg n "$1" '[.status.workloadGenerations[]? | select(.name == $n) | .generations[].generation | tostring] | join(",")' <<<"$2"
}

show_status() {
  local runtime agents agent jdk generations artifact
  runtime="$(kube get runtimeimage "$RUNTIME_ID" -o json)"
  agents="$(agents_on_runtime)"
  [ -n "$agents" ] || die "no agent runs on $RUNTIME_ID: deploy one first, for example 'make agent AGENT=java-spring'"
  log "runtime $RUNTIME_ID: generation $(jq -r '.status.generation' <<<"$runtime"), image $(jq -r '.status.digest' <<<"$runtime" | cut -c1-19)"
  printf '  %-16s %-26s %-4s %s\n' AGENT "JDK (live, from /runtime)" GEN "ARTIFACT (the app's own bytes)"
  for agent in $agents; do
    jdk="$(agent_runtime "$agent" 2>/dev/null | jq -r '"\(.language.version) \(.language.vendor)"' 2>/dev/null)" || jdk=""
    generations="$(workload_generations "$agent" "$runtime")"
    artifact="$(kube -n "$AGENT_NAMESPACE" get pods -l "app.kubernetes.io/name=$agent" \
      -o jsonpath='{.items[0].metadata.annotations.brewlet\.sh/artifact-digest}' 2>/dev/null)" || artifact=""
    printf '  %-16s %-26s %-4s %s\n' "$agent" "${jdk:-unreachable}" "${generations:--}" "${artifact:0:19}"
  done
}

# The previous generation is the approved image with an older JDK laid over /usr/jdk. It lives in
# the local registry next to the agent artifacts.
build_previous_runtime() {
  if [ -n "$(registry_digest "$PREVIOUS_REPO" "$ROTATION_JDK_VERSION")" ]; then
    ok "the previous runtime $PREVIOUS_IMAGE is already in the registry"
    return
  fi
  local arch version
  arch="$(host_arch)"
  log "building $PREVIOUS_IMAGE: the approved image with the Microsoft Build of OpenJDK $ROTATION_JDK_VERSION over /usr/jdk (downloads about 200 MB)"
  docker build --platform "linux/$arch" --provenance=false --sbom=false \
    --build-arg "FETCH_IMAGE=$FETCH_IMAGE" \
    --build-arg "RUNTIME_IMAGE=$APPROVED_IMAGE" \
    --build-arg "JDK_VERSION=$ROTATION_JDK_VERSION" \
    --build-arg "JDK_SHA256_LINUX_ARM64=$ROTATION_JDK_SHA256_LINUX_ARM64" \
    --build-arg "JDK_SHA256_LINUX_X64=$ROTATION_JDK_SHA256_LINUX_X64" \
    -t "$PREVIOUS_IMAGE" "$ROOT/demo/rotation"
  version="$(docker run --rm --entrypoint /usr/jdk/bin/java "$PREVIOUS_IMAGE" -version 2>&1 | head -n1)"
  case "$version" in
    *"$ROTATION_JDK_VERSION"*) ok "the image reports: $version" ;;
    *) die "the previous runtime reports '$version', expected $ROTATION_JDK_VERSION" ;;
  esac
  docker push "$PREVIOUS_IMAGE" >/dev/null
}

# Running Pods keep the runtime generation they started with. Brewlet's operator replaces the Pods
# of Deployments that opted in (brewlet.sh/restart-on-rotation) when the chart enables
# operator.rotationRestarts, which scripts/platform/cluster-up.sh does. Give it a minute, then restart by
# hand whatever it left alone so the demo also works on a cluster installed without it.
roll_agents() { # BEFORE: the output of deployment_generations taken before the rotation
  local before="$1" name generation pending="" waited=0
  while :; do
    pending=""
    while read -r name generation; do
      [ -n "$name" ] || continue
      [ "$(kube -n "$AGENT_NAMESPACE" get deployment "$name" -o jsonpath='{.metadata.generation}')" != "$generation" ] \
        || pending="$pending $name"
    done <<<"$before"
    [ -n "$pending" ] || break
    [ "$waited" -lt 60 ] || break
    sleep 5
    waited=$((waited + 5))
  done
  if [ -n "$pending" ]; then
    warn "Brewlet's operator did not restart:$pending (operator.rotationRestarts is off?); restarting by hand"
    for name in $pending; do kube -n "$AGENT_NAMESPACE" rollout restart "deployment/$name" >/dev/null; done
  else
    ok "Brewlet's operator restarted every agent that opted in"
  fi
  for name in $(agents_on_runtime); do
    kube -n "$AGENT_NAMESPACE" rollout status "deployment/$name" --timeout=5m
  done
  wait_for_workload_generations
}

# The operator records the generation of a workload's Pods a few seconds after its rollout ends.
# Wait for that, so the table that follows shows the generation the agents run on now.
wait_for_workload_generations() {
  local runtime generation agent stale waited=0
  while :; do
    runtime="$(kube get runtimeimage "$RUNTIME_ID" -o json)"
    generation="$(jq -r '.status.generation' <<<"$runtime")"
    stale=""
    for agent in $(agents_on_runtime); do
      [ "$(workload_generations "$agent" "$runtime")" = "$generation" ] || stale="$stale $agent"
    done
    [ -n "$stale" ] && [ "$waited" -lt 60 ] || break
    sleep 2
    waited=$((waited + 2))
  done
  [ -z "$stale" ] || warn "Brewlet has not recorded generation $generation for:$stale"
}

rotate_to() { # IMAGE
  local before
  before="$(deployment_generations)"
  "$ROOT/scripts/platform/runtime-rotate.sh" "$RUNTIME_ID" "$1"
  roll_agents "$before"
}

previous() {
  build_previous_runtime
  if [ "$(current_digest)" = "$(registry_digest "$PREVIOUS_REPO" "$ROTATION_JDK_VERSION")" ]; then
    ok "$RUNTIME_ID already runs the previous JDK"
  else
    log "Ops rewinds $RUNTIME_ID to the Microsoft Build of OpenJDK $ROTATION_JDK_VERSION"
    rotate_to "$PREVIOUS_IMAGE"
  fi
  show_status
}

current() {
  if [ "$(current_digest)" = "${APPROVED_IMAGE##*@}" ]; then
    ok "$RUNTIME_ID already runs the approved image"
  else
    log "Patch day: Ops rotates $RUNTIME_ID to the approved image. No agent is rebuilt."
    rotate_to "$APPROVED_IMAGE"
  fi
  show_status
}

case "${1:-all}" in
  status)   show_status ;;
  previous) previous ;;
  current)  current ;;
  all)      show_status; previous; current ;;
  *)        die "usage: $(basename "$0") [status|previous|current|all]" ;;
esac
