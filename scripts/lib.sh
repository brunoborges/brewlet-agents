#!/usr/bin/env bash
# Shared helpers for every script in this repository.
# Source this file; do not execute it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Path of an agent in the repository, with a helpful failure.
agent_dir() { local d="$ROOT/agents/$1"; [ -d "$d" ] || die "unknown agent: $1 (see 'make list')"; echo "$d"; }

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

# The agents' namespace. Pod Security "restricted" is enforced, so every agent Pod has to comply.
ensure_agent_namespace() {
  kube get namespace "$AGENT_NAMESPACE" >/dev/null 2>&1 || kube create namespace "$AGENT_NAMESPACE" >/dev/null
  kube label namespace "$AGENT_NAMESPACE" --overwrite pod-security.kubernetes.io/enforce=restricted >/dev/null
}

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
