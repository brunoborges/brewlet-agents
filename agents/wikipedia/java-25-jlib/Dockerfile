# syntax=docker/dockerfile:1
# check=skip=InvalidDefaultArgInFrom
#
# The java-25-jlib runtime: the approved java-25 runtime image (runtimes/java-25.env) with the
# jlib-inspector Java agent on top.
#
# Nothing but the agent differs from java-25: same distroless base, same JDK, same uid and layout,
# so the runtime id keeps the compatibility promise java-25 makes. The agent is attached through
# JDK_JAVA_OPTIONS, which every java launcher reads, so an application on this runtime is inspected
# without knowing it: its artifact, its launch.json and its Pod carry no agent. Brewlet does not
# inject agents; this is Ops baking one into a runtime it approves.
#
# "otel" exports what the agent finds as OpenTelemetry log events to the OTLP endpoint in
# OTEL_EXPORTER_OTLP_ENDPOINT, and JLIB_SERVER_URL sends the same inventory to a jlib-inspector
# server; an application opts into either by setting the variable in its Pod. Without one the agent
# only prints its report when the JVM exits. The report repeats every 30 seconds.
#
# Built by scripts/platform/runtime-build.sh; every value comes from versions.env and runtimes/java-25.env.
# The base images are build arguments without defaults on purpose: those files are the only place
# they are pinned.
ARG FETCH_IMAGE
ARG RUNTIME_IMAGE

FROM ${FETCH_IMAGE} AS jlib
ARG JLIB_INSPECTOR_VERSION
ARG JLIB_INSPECTOR_SHA256_AGENT
RUN apk add --no-cache curl
# The modes are set here and the tree is copied as it is. COPY --chmod would also apply to the
# directories it creates, and a directory without the search bit hides the jar from the runtime user.
RUN set -eu; \
    install -d -m 0755 /stage/opt/jlib-inspector; \
    curl -fsSL --retry 5 --retry-all-errors -o /stage/opt/jlib-inspector/jlib-inspector-agent.jar \
      "https://github.com/brunoborges/jlib-inspector/releases/download/v${JLIB_INSPECTOR_VERSION}/jlib-inspector-agent-${JLIB_INSPECTOR_VERSION}-shaded.jar"; \
    echo "${JLIB_INSPECTOR_SHA256_AGENT}  /stage/opt/jlib-inspector/jlib-inspector-agent.jar" | sha256sum -c -; \
    chmod 0644 /stage/opt/jlib-inspector/jlib-inspector-agent.jar

FROM ${RUNTIME_IMAGE}
COPY --from=jlib /stage/ /
ENV JDK_JAVA_OPTIONS="-javaagent:/opt/jlib-inspector/jlib-inspector-agent.jar=otel,interval:30s"
