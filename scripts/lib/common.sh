#!/usr/bin/env bash
# Shared helpers for every script in this repository.
# Source this file; do not execute it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/build"

# versions.env is the single source of truth for pinned versions.
set -a
# shellcheck disable=SC1091
source "$ROOT/versions.env"
set +a

# Never touch the user's default kubeconfig or any other cluster: every script
# uses a repository-private kubeconfig.
export KUBECONFIG="$BUILD_DIR/kubeconfig"
export PATH="$ROOT/.bin:$PATH"

# Registry address as seen from the host and from containerd on the kind node.
REGISTRY_HOST="localhost:${REGISTRY_PORT}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  local missing=0
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { warn "missing required tool: $tool"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install the tools above and retry"
}

# linux/<arch> of the Docker VM. kind nodes and every image must match it,
# otherwise Apple-silicon hosts fail with exec format errors.
host_arch() {
  case "$(docker info --format '{{.Architecture}}')" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported Docker architecture: $(docker info --format '{{.Architecture}}')" ;;
  esac
}

# A workload is either a Runtime Concierge agent (agents/<name>, settings in agent.env) or an app
# (agents/wikipedia/<name>, settings in app.env): anything else that runs on a Brewlet runtime. Names are
# unique across both, and the scripts that build, publish and deploy treat them alike.
#
# Path of a workload in the repository, with a helpful failure.
agent_dir() {
  if [ -f "$ROOT/agents/$1/agent.env" ]; then echo "$ROOT/agents/$1"; return 0; fi
  if [ -f "$ROOT/agents/wikipedia/$1/app.env" ]; then echo "$ROOT/agents/wikipedia/$1"; return 0; fi
  die "unknown agent or app: $1 (see 'make list')"
}

# Keep build output and image repositories independent of the source layout.
workload_kind() { if [ -f "$ROOT/agents/$1/agent.env" ]; then echo agents; else echo apps; fi; }

# The file with a workload's settings (the argument is its directory).
workload_env() { if [ -f "$1/agent.env" ]; then echo "$1/agent.env"; else echo "$1/app.env"; fi; }

# Build output and image repository of a workload: build/<kind>/<name> and <kind>/<name>.
artifact_out()  { echo "$BUILD_DIR/$(workload_kind "$1")/$1"; }
artifact_repo() { echo "$(workload_kind "$1")/$1"; }

# Namespace a workload is deployed to: NAMESPACE in its app.env, otherwise the agents' namespace.
workload_namespace() {
  local ns
  ns="$(env_value "$(workload_env "$(agent_dir "$1")")" NAMESPACE)"
  echo "${ns:-$AGENT_NAMESPACE}"
}

# Name of the container that runs the workload's own code: "agent" in an agent's Pod, "app" in an
# app's. It is also the suffix of the Pod's runtime-image.brewlet.sh/<container> annotation.
workload_container() { if [ "$(workload_kind "$1")" = agents ]; then echo agent; else echo app; fi; }

# Whether a workload's Pod carries the Copilot CLI sidecar. Agents always do; an app opts in with
# SIDECAR=copilot-cli in its app.env.
workload_has_sidecar() {
  local dir
  dir="$(agent_dir "$1")"
  [ -f "$dir/agent.env" ] || [ "$(env_value "$dir/app.env" SIDECAR)" = "$SIDECAR_NAME" ]
}

# Reads KEY from a simple KEY=VALUE file without sourcing arbitrary code.
env_value() { sed -n "s/^$2=//p" "$1" | head -n1; }

# Image reference of the Copilot CLI sidecar: <registry>/copilot-cli:<cli-version>.
sidecar_ref() { echo "$REGISTRY_HOST/${SIDECAR_NAME}:${COPILOT_CLI_VERSION}"; }

# Digest (sha256:...) a tag currently resolves to in the local registry.
registry_digest() {
  local repo="$1" tag="$2"
  curl -fsSI \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "http://$REGISTRY_HOST/v2/$repo/manifests/$tag" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

kube() { kubectl --kubeconfig "$KUBECONFIG" --context "kind-${CLUSTER_NAME}" "$@"; }

# GET /runtime of a deployed agent through the API server's service proxy: no port-forward to
# start or stop. Prints the JSON document the Runtime Concierge builds from its live process.
agent_runtime() { kube get --raw "/api/v1/namespaces/${AGENT_NAMESPACE}/services/$1:80/proxy/runtime"; }

# Port-forward to a Service on a free local port, for a script that talks to it with curl.
# forward_start NAMESPACE SERVICE PORT sets FORWARD_PORT; the caller's EXIT trap runs forward_stop.
# kubectl is started directly (not through kube()) so that $! is its own PID.
FORWARD_PID=""
FORWARD_PORT=""
forward_start() {
  local log _
  log="$(mktemp)"
  kubectl --kubeconfig "$KUBECONFIG" --context "kind-${CLUSTER_NAME}" -n "$1" \
    port-forward "svc/$2" ":$3" >"$log" 2>&1 &
  FORWARD_PID=$!
  for _ in $(seq 1 30); do
    FORWARD_PORT="$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\) -> .*/\1/p' "$log" | head -n1)"
    [ -z "$FORWARD_PORT" ] || break
    kill -0 "$FORWARD_PID" 2>/dev/null || { cat "$log" >&2; rm -f "$log"; die "port-forward to $1/$2 failed: is it deployed?"; }
    sleep 1
  done
  rm -f "$log"
  [ -n "$FORWARD_PORT" ] || die "port-forward to $1/$2 did not start"
}
forward_stop() {
  if [ -n "$FORWARD_PID" ]; then
    kill "$FORWARD_PID" 2>/dev/null || true
    wait "$FORWARD_PID" 2>/dev/null || true
    FORWARD_PID=""
  fi
}

# A workload namespace. Pod Security "restricted" is enforced, so every Pod in it has to comply.
ensure_namespace() {
  kube get namespace "$1" >/dev/null 2>&1 || kube create namespace "$1" >/dev/null
  kube label namespace "$1" --overwrite pod-security.kubernetes.io/enforce=restricted >/dev/null
}

# The agents' namespace.
ensure_agent_namespace() { ensure_namespace "$AGENT_NAMESPACE"; }

# The Secret an agent and its sidecar share. It always holds a random connection token that the
# SDK must present to the Copilot CLI; 'make auth' adds the optional github-token key later.
# Values travel on stdin, never on a command line, and 'create' (unlike 'apply') leaves no
# last-applied annotation that would copy them.
ensure_agent_secret() {
  kube -n "$AGENT_NAMESPACE" get secret "$AGENT_SECRET" >/dev/null 2>&1 && return 0
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  connection-token: %s\n' \
    "$AGENT_SECRET" "$AGENT_NAMESPACE" "$(openssl rand -hex 32 | tr -d '\n' | base64 | tr -d '\n')" | kube create -f - >/dev/null
}

# Retries a command while a slow-starting webhook or controller comes up.
retry() {
  local attempts="$1"; shift
  local n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -lt "$attempts" ] || return 1
    sleep 5
  done
}
