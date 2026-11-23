# java-spring

Spring Boot 4 on Java 25: the Runtime Concierge as a thin jar on the plain `java-25` Brewlet runtime, with
Tomcat on virtual threads and the `copilot-spring-boot-starter` talking to the Copilot CLI sidecar. This is the
reference agent: the other seven implement the same [contract](../README.md).

## What is in the artifact

```text
/app/app.jar     layer "code"    thin jar: the app's classes, application.yml, prompts/concierge.md
/app/lib/*.jar   layer "deps"    42 libraries: Spring, Tomcat, Jackson, Logback, Copilot SDK + starter
launch.json      launch layer    /usr/jdk/bin/java -XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -jar /app/app.jar
```

| layer | compressed |
| --- | --- |
| deps | 27.7 MiB |
| code | 16.3 KiB |
| launch | 274 B |
| whole artifact | 27.7 MiB (31 MB unpacked, linux/arm64) |

Deliberately **not** in it: the JDK (`/usr/jdk` comes from the `java-25` runtime image) and the Copilot CLI (it
runs in the sidecar). The files over 2 MB are `copilot-sdk-2.0.1.jar` (7.9 MiB, class files only), Tomcat,
`spring-web` and `spring-core`.

Measured on the kind cluster; [`deployment.yaml`](deployment.yaml) asks for 100m CPU, 256Mi, limit 512Mi:

| working set | fresh Pod | after two asks |
| --- | --- | --- |
| agent | 169 MiB | 183 MiB |
| Copilot CLI sidecar | 16 MiB | 52 MiB |

Startup is 1.1-1.2 s (`Started ConciergeApplication in 1.096 seconds`). `make agent` from scratch takes about
22 s with a warm Maven cache. `make footprint` prints these numbers for whatever is deployed.

## How the integration is used

The agent is an interface; the starter generates the implementation. The system prompt is a classpath resource,
the same file in every agent:

```java
@CopilotAgent(name = "concierge", instructionsResource = "classpath:/prompts/concierge.md", toolRefs = "runtimeFacts")
public interface ConciergeAgent {
    CompletableFuture<String> ask(@ConversationId String conversationId, @UserMessage String question);
}
```

The one tool is a Spring bean referenced by name; `/runtime` and the tool read the same facts object, so what the
model says and what the endpoint shows cannot drift apart:

```java
@Service
public class RuntimeFacts {
    @CopilotTool(name = "runtime_facts", value = "Verified facts about the environment this agent runs in ...")
    public String runtimeFacts(@CopilotToolParam("Which part: all, language, agent, copilot or deployment") String topic)
```

Everything else is configuration ([`application.yml`](src/main/resources/application.yml)):

```yaml
copilot:
  cli-url: ${COPILOT_CLI_URL}                       # no defaults: a wrong Pod fails at startup
  tcp-connection-token: ${COPILOT_CONNECTION_TOKEN}
  agents:
    concierge:
      available-tools: ["custom:*"]                 # only the agent's own tool, see Gotchas
      response-timeout: 2m
      permissions: { allow-agent-tools: true }
```

`ConciergeController` implements `/healthz`, `/readyz`, `/runtime` and `POST /ask`; `SidecarProbe` pings and
describes the sidecar through the starter's `CopilotClient` bean. The framework version comes from
`SpringBootVersion`, the SDK and starter versions and locations from their jars, the JDK home from `java.home`
(`/usr/jdk`).

## Build notes

* Host tools: Maven 3.9+ and JDK 25. `scripts/integrations/mvn.sh` points Maven at the shared `build/m2`, where
  `scripts/integrations/build.sh java` installed the starter and its core.
* Pure Java, so there is one platform-neutral build. The runtime ABI is `maven.compiler.release=25`, the Ops
  `java-25` runtime.
* Layering without a fat jar: [`build.sh`](build.sh) runs `java -Djarmode=tools -jar target/app.jar extract`,
  which splits Spring Boot's jar into a thin `app.jar` (its manifest has `Class-Path: lib/...`) and `lib/`. The
  libraries become the `deps` layer and the jar the `code` layer ([`layers`](layers)), so a code change ships
  16 KiB instead of 28 MiB.
* Reproducible: Brewlet keeps file mtimes in the layer tarballs, so `package_artifact` pins them. Rebuilding
  unchanged sources gives the same artifact digest (checked twice, digest `sha256:86643a3e65fe...`), and
  `make layers AGENT=java-spring` shows the per-layer digests.

## Run it

After `make up` from the repository root, run `make run` **in this directory** to build, publish,
deploy and smoke-test this agent. Use `./build.sh` to build just the artifact.

From the repository root:

```bash
make agent AGENT=java-spring         # build, publish, deploy, smoke test (make auth for the /ask checks)
make whoami AGENT=java-spring        # what the agent reports about its own runtime
make ask AGENT=java-spring Q="Which JDK are you on, and where is it installed?"
# I'm on a Microsoft build of OpenJDK, version 25.0.5.1+2-LTS. It's installed at `/usr/jdk`. Brewlet provides
# this JDK as a platform-owned runtime image, so it isn't bundled in my application artifact.
```

## Gotchas

* **`built-in-tools: false` is not enough.** It only adds `builtin:*` to the deny-list: the shell and file tools
  disappear, but the Copilot CLI's own GitHub MCP tools (`github-mcp-server-*`, which can read repositories with
  the sidecar's token) and `web_search` stay listed and callable. `available-tools: ["custom:*"]` is an
  allow-list over every tool source, and the model then lists only `runtime_facts`. The two settings cannot be
  combined, and the allow-list must name `custom:*`, or startup validation fails because it would hide the
  agent's own tool. `make smoke` asks the model to list its tools and fails if anything else shows up.
* Spring Boot 4 renamed the starter: it is `spring-boot-starter-webmvc`, not `spring-boot-starter-web`.
* The pom names `CopilotToolProcessor` explicitly in `annotationProcessors`; that is what turns `@CopilotTool`
  into the tool definition the model sees.
* `copilot.cli-url` and `copilot.tcp-connection-token` have no defaults on purpose: the Pod spec provides both
  (`COPILOT_CLI_URL=127.0.0.1:4321`, the connection token from a Secret), and a Pod without them should fail loudly.
* The container's root filesystem is read-only: Tomcat's work directory defaults to `java.io.tmpdir`, which is
  `/tmp`, an `emptyDir` in the Pod, so nothing else needs to be writable.
