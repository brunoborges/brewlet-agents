# java-micronaut

Micronaut 5 on Java 25: the Runtime Concierge as a thin jar on the plain `java-25` Brewlet runtime, with
compile-time DI, a Netty server and the `copilot-micronaut` integration talking to the Copilot CLI sidecar.

## What is in the artifact

```text
/app/app.jar     layer "code"    thin jar: the app's classes, application.yml, logback.xml, prompts/concierge.md
/app/lib/*.jar   layer "deps"    49 libraries: Micronaut, Netty, Copilot SDK + integration, Jackson, Logback
launch.json      launch layer    /usr/jdk/bin/java -XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -jar /app/app.jar
```

| layer | compressed |
| --- | --- |
| deps | 23,829,176 B |
| code | 42,344 B |
| launch | 274 B |
| whole artifact (with config and manifest) | 22.8 MiB (25.9 MiB unpacked, linux/arm64) |

Deliberately **not** in it: the JDK (`/usr/jdk` comes from the `java-25` runtime image) and the Copilot CLI
(it runs in the sidecar). The only file over 3 MB is `copilot-sdk-2.0.1.jar` (7.9 MiB, class files only).

Measured on the kind cluster; [`agent.env`](agent.env) asks for 100m CPU, 192Mi, limit 384Mi:

| working set | idle | after asks | 4 concurrent asks |
| --- | --- | --- | --- |
| agent | 120 MiB | 145 MiB | 146 MiB |
| Copilot CLI sidecar | 17 MiB | 30-60 MiB | 88 MiB |

Startup is 0.5-0.9 s (`Startup completed in 533ms`). `make agent` from scratch takes about 25 s with a warm
Maven cache (about 11 s of Maven when cold).

## How the integration is used

The agent is an interface; the integration's annotation processor generates the bean at compile time. The
system prompt is a classpath resource, the same file in every agent:

```java
@CopilotAgent(name = "concierge", instructionsResource = "classpath:/prompts/concierge.md", toolRefs = "runtimeFacts")
public interface ConciergeAgent {
    CompletableFuture<String> ask(@ConversationId String conversationId, @UserMessage String question);
}
```

The one tool is a bean referenced by name; `/runtime` and the tool read the same facts object:

```java
@Singleton @Named("runtimeFacts")
public class RuntimeFacts {
    @CopilotTool(name = "runtime_facts", value = "Verified facts about the environment this agent runs in ...")
    public String runtimeFacts(@CopilotToolParam("Which part: all, language, agent, copilot or deployment") String topic)
```

Everything else is configuration ([`application.yml`](src/main/resources/application.yml)):

```yaml
micronaut:
  server: { port: "${PORT:8080}", host: 0.0.0.0 }
  copilot:
    cli-url: ${COPILOT_CLI_URL}                       # no defaults: a wrong Pod fails at startup
    tcp-connection-token: ${COPILOT_CONNECTION_TOKEN}
    agents:
      concierge:
        available-tools: ["custom:*"]                 # only the agent's own tool, see Gotchas
        response-timeout: 2m
        permissions: { allow-agent-tools: true }
```

`ConciergeController` has `/healthz` (event loop) and `/readyz`, `/runtime`, `POST /ask` (blocking executor, which
is virtual threads). `SidecarProbe` pings the sidecar through the integration's `CopilotClient` bean.
The framework version comes from `VersionUtils.getMicronautVersion()`, the SDK and integration versions and
locations from their jars, the JDK home from `java.home` (`/usr/jdk`).

## Build notes

* Host tools: Maven 3.9+ and JDK 25. `scripts/mvn.sh` points Maven at the shared `build/m2`, where
  `scripts/integrations-build.sh java` installed `copilot-micronaut` and its processor.
* Pure Java, so there is one platform-neutral build. The runtime ABI is `maven.compiler.release=25`, the Ops
  `java-25` runtime.
* Compile-time DI: `maven-compiler-plugin` puts `micronaut-inject-java`, `micronaut-serde-processor`, the
  integration's `copilot-micronaut-processor` and the SDK (its `CopilotToolProcessor` handles `@CopilotTool`) on
  `annotationProcessorPaths`, and names every processor in `annotationProcessors`: the SDK jar also registers an
  experimental-API checker that would reject the tool processor's generated code, so that one is left out.
* Layering without a fat jar: `maven-jar-plugin` writes a thin `app.jar` whose manifest has
  `Class-Path: lib/...`, `maven-dependency-plugin` copies the libraries to `target/lib`, and [`build.sh`](build.sh)
  puts `lib/` in the `deps` layer and `app.jar` in the `code` layer ([`layers`](layers)).
* Reproducible: `project.build.outputTimestamp` makes the jar deterministic and `build.sh` pins the file times,
  because Brewlet keeps mtimes in the layer tarballs. Rebuilding unchanged sources gives the same digest, and a
  code change replaces only the 42 KB code layer (checked: the deps layer digest stays identical).

## Run it

```bash
make agent AGENT=java-micronaut      # build, publish, deploy, smoke test (make auth for the /ask check)
kubectl -n agents port-forward svc/java-micronaut 8080:80 &
curl -s localhost:8080/runtime | jq '.agent, .language'
curl -s localhost:8080/ask -H 'content-type: application/json' \
  -d '{"question":"Which language runtime are you on and where is it installed?"}'
# {"answer":"You're on Java (Microsoft build), version 25.0.5.1+2-LTS. It's installed at `/usr/jdk`.","conversationId":"..."}
```

## Gotchas

* **`built-in-tools: false` is not enough.** It only adds `builtin:*` to the deny-list: the shell and file tools
  disappear, but the Copilot CLI's own GitHub MCP tools (`github-mcp-server-*`) and `web_search` stay listed and
  callable (verified by asking the model to call them). `available-tools: ["custom:*"]` is an allow-list over
  every tool source: the model now lists only `runtime_facts` and the others are unavailable. The two settings
  cannot be combined, and the allow-list must name `custom:*`, or startup validation fails because it would hide
  the agent's own tool.
* Micronaut placeholders do not nest: `${POD_NAME:${HOSTNAME:x}}` resolves to the string `x}`. Use one level.
* `application.yml` needs SnakeYAML on the classpath (`org.yaml:snakeyaml`, runtime scope), and Micronaut 5 does not
  bring it. Without it the file is silently ignored and startup fails with a misleading
  `Failed to inject value for parameter [endpoint]` although `COPILOT_CLI_URL` is set.
* The tool bean needs `@Named("runtimeFacts")` so that `toolRefs = "runtimeFacts"` can find it.
* Micronaut Serde needs request records marked `@Serdeable.Deserializable` with `@Nullable` components,
  otherwise `{}` is a Serde error instead of the contract's `400 bad_request`.
* `micronaut-core` ships no `pom.properties`, hence `VersionUtils` for the framework version.
* javac prints "Supported source version 'RELEASE_17' from annotation processor CopilotToolProcessor": harmless.
* The container's root filesystem is read-only; Micronaut and Netty write nothing outside `/tmp`.
