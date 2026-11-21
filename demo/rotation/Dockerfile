# syntax=docker/dockerfile:1
#
# The "before the patch" generation of the java-25 runtime, for the rotation demo.
#
# It is the runtime image Ops approved (runtimes/java-25.env) with an older Microsoft Build of
# OpenJDK laid over /usr/jdk, so the only difference between the two generations is the JDK: same
# distroless base, same uid, same layout. A runtime id is a compatibility promise and a rotation
# keeps it.
#
# Built by scripts/demo-rotation.sh; every value comes from versions.env.
ARG FETCH_IMAGE
ARG RUNTIME_IMAGE

FROM ${FETCH_IMAGE} AS jdk
ARG JDK_VERSION
ARG JDK_SHA256_LINUX_ARM64
ARG JDK_SHA256_LINUX_X64
ARG TARGETARCH
RUN apk add --no-cache curl
RUN set -eu; \
    case "${TARGETARCH}" in \
      arm64) arch=aarch64; sha256="${JDK_SHA256_LINUX_ARM64}" ;; \
      amd64) arch=x64;     sha256="${JDK_SHA256_LINUX_X64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-all-errors -o /tmp/jdk.tar.gz \
      "https://aka.ms/download-jdk/microsoft-jdk-${JDK_VERSION}-linux-${arch}.tar.gz"; \
    echo "${sha256}  /tmp/jdk.tar.gz" | sha256sum -c -; \
    mkdir /jdk; \
    tar -xzf /tmp/jdk.tar.gz -C /jdk --strip-components=1

FROM ${RUNTIME_IMAGE}
COPY --from=jdk /jdk /usr/jdk
