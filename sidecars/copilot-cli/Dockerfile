# syntax=docker/dockerfile:1.7
#
# copilot-cli: the sidecar container every agent Pod shares.
#
# It serves the Copilot SDK protocol on 127.0.0.1:4321. Containers in a Pod share
# one network namespace, so the agent reaches the CLI over loopback while nothing
# else in the cluster can. The agent artifact carries no CLI and never sees the
# GitHub token: credentials live only in this container.
#
# Build context: ./sidecars/copilot-cli   (see scripts/platform/sidecar-build.sh)
ARG FETCH_IMAGE
ARG SIDECAR_BASE_IMAGE

# ---------------------------------------------------------------------------
# 1. Download the CLI release and verify the SHA-256 pinned in versions.env.
# ---------------------------------------------------------------------------
FROM ${FETCH_IMAGE} AS cli
ARG TARGETARCH
ARG COPILOT_CLI_VERSION
ARG COPILOT_CLI_SHA256_LINUX_ARM64
ARG COPILOT_CLI_SHA256_LINUX_X64
RUN apk add --no-cache curl
COPY fetch-copilot-cli.sh /usr/local/bin/fetch-copilot-cli.sh
RUN fetch-copilot-cli.sh

# ---------------------------------------------------------------------------
# 2. The sidecar: a distroless glibc base, a non-root user, nothing else.
# ---------------------------------------------------------------------------
FROM ${SIDECAR_BASE_IMAGE}
ARG COPILOT_CLI_VERSION
LABEL org.opencontainers.image.title="copilot-cli" \
      org.opencontainers.image.description="GitHub Copilot CLI as an SDK server sidecar for Brewlet agent Pods" \
      org.opencontainers.image.version="${COPILOT_CLI_VERSION}" \
      org.opencontainers.image.source="https://github.com/brunoborges/brewlet-agents"

COPY --from=cli --chown=0:0 /opt/copilot/cli /opt/copilot/cli

# The root filesystem is read-only in the Pod. Everything the CLI writes goes
# under /tmp, which the Pod mounts as an emptyDir.
ENV HOME=/tmp \
    COPILOT_HOME=/tmp/.copilot \
    XDG_CONFIG_HOME=/tmp/.config \
    XDG_CACHE_HOME=/tmp/.cache \
    XDG_STATE_HOME=/tmp/.state
USER 65532:65532
EXPOSE 4321

# COPILOT_CONNECTION_TOKEN (set by the Pod) is the shared secret the SDK sends
# first; without it the CLI accepts any local connection, so the Pod always sets it.
# --no-auto-login stops the CLI hunting for ambient credentials, and
# --auth-token-env names the one variable it may authenticate with: the optional
# COPILOT_GITHUB_TOKEN from the Pod's Secret. Unset, the CLI starts unauthenticated.
ENTRYPOINT ["/opt/copilot/cli/copilot-runtime"]
CMD ["--headless", "--no-auto-update", "--no-auto-login", "--auth-token-env", "COPILOT_GITHUB_TOKEN", "--port", "4321"]
