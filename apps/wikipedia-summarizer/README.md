# wikipedia-summarizer

A Copilot SDK agent that summarizes a Wikipedia article. You give it the address of an article; it fetches the
text from Wikipedia and has Copilot write a short summary with key points. The only way in is a REST API: there
is no page of its own (the Node.js [front-end](../wikipedia-frontend/README.md) is a separate app in front of it).

It is Spring Boot 4 on Java 25 with the `copilot-spring-boot-starter`, the same stack as the
[`java-spring`](../../agents/java-spring/README.md) agent, and it runs in a Pod with the same Copilot CLI sidecar.
The one difference in the platform is the runtime: it selects
[`java-25-jlib`](../../docs/observability.md#the-java-25-jlib-runtime), `java-25` plus the jlib-inspector agent, so
the jars it loads show up in the [observability](../../docs/observability.md) stack.

## The API

```bash
make wikipedia                                   # deploy it (and the front-end)
make summarize URL='https://en.wikipedia.org/wiki/Java_(programming_language)'
```

`make summarize` is a port-forward and one request. By hand, with your own port-forward, that is:

```bash
kubectl -n agents port-forward svc/wikipedia-summarizer 8080:80 &
curl -s http://localhost:8080/api/summaries -H 'Content-Type: application/json' \
  -d '{"url": "https://en.wikipedia.org/wiki/Java_(programming_language)"}'
```

```json
{
  "url": "https://en.wikipedia.org/wiki/Java_(programming_language)",
  "title": "Java (programming language)",
  "summary": "Java is a high-level, general-purpose, memory-safe, object-oriented programming language ...\n\n**Key points**\n- ...",
  "truncated": false
}
```

`url` is the article's canonical address: a link to a redirect (`/wiki/HTTPS` for `Hypertext_Transfer_Protocol_Secure`)
comes back as the page it lands on. `summary` is one paragraph of at most 120 words and then three to six key
points, in the language of the article. A disambiguation page is summarized as the list of its main meanings.
`truncated` is `true` when the article was longer than the agent reads (60 000 characters, about 15 000 tokens);
the model is told, and says so at the end of the summary.

| Request | Response |
| --- | --- |
| `POST /api/summaries` | `200` with the document above, or an error. Takes `{"url": "..."}`. |
| `GET /healthz` | `200 {"status":"UP"}`. Liveness; never depends on the sidecar. |
| `GET /readyz` | `200 {"status":"READY"}` once the Copilot CLI sidecar answers a ping, otherwise `503 {"status":"NOT_READY","reason":"copilot_cli_unreachable"}`. |

Every error is `{"error": "<code>", "message": "<what to change>"}`:

| Status | `error` | When |
| --- | --- | --- |
| 400 | `bad_request` | No body, no `url`, or an address the agent does not accept (see below) |
| 404 | `article_not_found` | Wikipedia has no article with that title |
| 422 | `no_article_text` | The page exists but has no text to summarize (a file page, for example) |
| 502 | `wikipedia_unavailable` | Wikipedia did not answer, answered with an error, or sent more than 8 MiB |
| 502 | `agent_error` | The model failed, or answered with nothing |
| 503 | `copilot_not_authenticated` | The Copilot CLI in the cluster has no GitHub credentials: run `make auth` |
| 503 | `copilot_unavailable` | The sidecar is not reachable |
| 503 | `interrupted` | The thread waiting for the model was interrupted |
| 504 | `timeout` | The model needed more than two minutes |

The authentication check comes first: without credentials the answer is a `503` straight away, before anything
is fetched from Wikipedia.

### Which addresses are accepted

The agent is a server that fetches a URL on a caller's behalf, so it does not fetch the caller's URL. It checks
the address, takes the language and the title out of it, and builds its own request to the MediaWiki API:

* `https` only, no credentials in the address, no port other than 443, at most 2048 characters;
* the host is `<language>.wikipedia.org` (a mobile `<language>.m.wikipedia.org` address works and is
  normalized); nothing else, so `en.wikipedia.org.example.com` and `example.com` are refused;
* the path starts with `/wiki/`; `_` becomes a space and `+` is kept, so `/wiki/C++` works;
  a title is at most 256 characters and has no control characters;
* the MediaWiki request never follows a redirect, and reads at most 8 MiB, in at most ten seconds.

The article is also untrusted input for the model. It is placed between two marker lines that carry a random
token which changes on every request, and the prompt says that whatever is between them is text to summarize,
never instructions.

## What is in the artifact

```text
/app/app.jar     layer "code"    thin jar: the app's classes, application.yml, prompts/summarizer.md
/app/lib/*.jar   layer "deps"    74 libraries: Spring, Tomcat, Jackson, Logback, OpenTelemetry, Copilot SDK + starter
launch.json      launch layer    /usr/jdk/bin/java -XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -jar /app/app.jar
```

| layer | compressed |
| --- | --- |
| deps | 35.6 MiB |
| code | 30.8 KiB |
| launch | 280 B |
| whole artifact | 35.6 MiB (linux/arm64) |

The jlib-inspector agent is not in it: `launch.json` names no agent, and the artifact is the same one that would
run on plain `java-25`. The agent comes with the runtime (`runtimeImages` selects `java-25-jlib`), and the
[`deployment.yaml`](deployment.yaml) only says where it should report. The app's own traces and metrics are in the
artifact, as libraries: see [Telemetry](#telemetry).

Measured on the kind cluster; the Deployment asks for 100m CPU, 256Mi, limit 512Mi:

| working set | fresh Pod | after two summaries |
| --- | --- | --- |
| agent | 182 MiB | 216 MiB |
| Copilot CLI sidecar | 17 MiB | 47 MiB |

Startup is 2.0 s (`Started SummarizerApplication in 2.018 seconds`). A summary takes 6 to 10 s, nearly all of
it the model. `make footprint` prints these numbers for what is deployed.

## How the integration is used

The agent is an interface; the starter generates the implementation. The system prompt is a classpath file
([`prompts/summarizer.md`](src/main/resources/prompts/summarizer.md)), not a string in the code:

```java
@CopilotAgent(name = "summarizer", instructionsResource = "classpath:/prompts/summarizer.md")
public interface ArticleSummarizer {
    CompletableFuture<String> summarize(@ConversationId String conversationId, @UserMessage String request);
}
```

Each summary is its own conversation: a random session id, deleted when the answer is back, so one reader's
article never sits in another's context (the starter's `cleanup.max-age: 1h` is the safety net for a Pod that
dies in between). The rest of the code is plain Spring:

| Class | Does |
| --- | --- |
| `SummarizerController` | `POST /api/summaries`, `/healthz`, `/readyz` |
| `WikipediaUrl` | Validates the address and takes the host and the title out of it |
| `WikipediaClient` | Fetches the plain text through the MediaWiki Action API (`prop=extracts&explaintext=1&redirects=1`) |
| `SummaryService` | Authentication check, truncation, the marker lines, the call to the agent, the timeout, and the two observations (`summarizer.fetch`, `summarizer.model`) |
| `ProbeObservationFilter` | Keeps the kubelet's `/healthz` and `/readyz` calls out of the traces and the metrics |
| `ApiExceptionHandler` | Turns `ApiException` and everything unexpected into the error documents above |
| `SidecarProbe` | Pings the sidecar and reads its authentication status through the starter's `CopilotClient` |

Everything that can change per environment is configuration ([`application.yml`](src/main/resources/application.yml)),
and an environment variable overrides each of them, except the connection token, which is a file (see the
[gotchas](#gotchas)):

| Setting | Default | Environment variable |
| --- | --- | --- |
| `copilot.cli-url` | none (the Pod sets `127.0.0.1:4321`) | `COPILOT_CLI_URL` |
| `copilot.tcp-connection-token` | none (the file `/app/secrets/connection-token`, from the Secret `copilot-cli`) | none: a file, read through `SPRING_CONFIG_IMPORT=configtree:/app/secrets/` |
| `summarizer.model-timeout` | `2m` | `SUMMARIZER_MODEL_TIMEOUT` |
| `summarizer.wikipedia.max-article-chars` | `60000` | `SUMMARIZER_WIKIPEDIA_MAX_ARTICLE_CHARS` |
| `server.port` | `8080` | `PORT` |

## Telemetry

The app exports its own **traces** and **metrics** over OTLP, through Spring Boot's OpenTelemetry starter
(`spring-boot-starter-opentelemetry`), next to the log events that the jlib-inspector agent of the runtime exports
for the jars it loads. All three arrive on one resource, `wikipedia-summarizer`, in the Aspire dashboard
([what each tab shows](../../docs/observability.md#traces-and-metrics-from-the-application)).

* **One trace per request:** `http post /api/summaries`, with `fetch article` and `ask model` under it, and the
  Copilot starter's own `copilot.agent.invocation` under `ask model`. `SummaryService` records the first two as
  Micrometer observations, because the JDK `HttpClient` that fetches the article is not instrumented by itself.
* **The Pod decides where it goes.** Spring Boot maps `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME` and
  `OTEL_RESOURCE_ATTRIBUTES`, the variables that already point the agent at Aspire, so the endpoint is not in
  [`application.yml`](src/main/resources/application.yml). That file keeps every trace
  (`management.tracing.sampling.probability: 1.0`) and publishes the metrics every 30 s.
* **The probes are left out.** The kubelet calls `/healthz` and `/readyz` every few seconds, and
  `ProbeObservationFilter` keeps those calls from burying the real requests.
* **Nothing from an article is recorded.** The only tags that come from the request are the Wikipedia host and
  whether the article was truncated. The title, the text, the prompt and the summary are never recorded, and the log
  is not exported.
* **To turn it off,** set `OTEL_TRACES_EXPORTER=none` and `OTEL_METRICS_EXPORTER=none`. Run on your machine with no
  collector, the metrics exporter logs a warning every 30 s: set both, or point `OTEL_EXPORTER_OTLP_ENDPOINT` at one.

## Build notes

* Host tools: Maven 3.9+ and JDK 25, the same as for the Java agents. `scripts/mvn.sh` points Maven at the shared
  `build/m2`, where `scripts/integrations-build.sh java` installed the starter.
* [`build.sh`](build.sh) runs `mvn clean package`, which includes the 52 unit tests (no network, no Copilot CLI),
  then splits Spring Boot's jar with `java -Djarmode=tools -jar target/app.jar extract` into the thin `app.jar` and
  `lib/`, as the `deps` and `code` layers ([`layers`](layers)). A code change ships 31 KiB instead of 36 MiB.
* The tests cover the pieces that can be checked without a model: the address rules (`WikipediaUrlTest`), the
  MediaWiki client against a local server (`WikipediaClientTest`), the service with a fake agent
  (`SummaryServiceTest`, which includes truncation, the marker lines and the two observations), the HTTP contract
  (`SummarizerApiTest`, every error code), that the probes are not observed (`ProbeObservationFilterTest`) and that
  the connection token is read from a mounted file (`ConnectionTokenFileTest`).

## Run it

```bash
make up && make observability        # the platform, then the telemetry stack the runtime reports to
make auth                            # once: the Copilot CLI sidecar needs your GitHub token
make wikipedia                       # build, publish, deploy and smoke-test this app and the front-end
make summarize URL='https://en.wikipedia.org/wiki/Kubernetes'
make smoke APP=wikipedia-summarizer  # the checks again: the contract above and one real summary
make logs APP=wikipedia-summarizer   # the app's log and the sidecar's
make telemetry                       # the jars of this app arrived in jlib-inspector and in Aspire, and so did its traces and metrics
```

`make smoke` is [`smoke.sh`](smoke.sh): readiness, seven kinds of bad request (each a `400 bad_request`), a missing
article (`404`) and a real summary of the article on Java. Without credentials in the cluster the summary step
expects the documented `503 copilot_not_authenticated`, so the checks pass on a cluster nobody has authenticated;
`REQUIRE_AUTH=1` makes the summary mandatory.

## Gotchas

* **The Copilot CLI takes `COPILOT_*` variables as its own settings.** A Service named `copilot` would make
  Kubernetes inject `COPILOT_PORT=tcp://...` into the Pod, which the CLI reads as its port. The Deployment sets
  `enableServiceLinks: false`, as the Copilot CLI container documentation advises.
* **The connection token is a file, not an environment variable.** The jlib-inspector agent of `java-25-jlib`
  sends every environment variable of the process to the jlib-server, which has no authentication, and the
  jlib-ui page shows them. The Deployment therefore mounts the key `connection-token` of the Secret `copilot-cli`
  read-only at `/app/secrets` (the volume lists only that key, so the GitHub token in the same Secret is not
  mounted), and `SPRING_CONFIG_IMPORT=configtree:/app/secrets/` makes the file the property `connection-token`,
  which `application.yml` hands to `copilot.tcp-connection-token`. Only the sidecar container gets the token as an
  environment variable, and the agent does not instrument it. The same goes for any other secret: no environment
  variable, no `-D` property, no argument. `make check` fails the manifest when the app container takes an
  environment variable from a Secret or has a credential-like name, or when a Secret volume has no `items`.
* **The agent has no tools.** It registers none, sets `available-tools: ["custom:*"]` (an allow-list over every tool
  source, the one that keeps the Copilot CLI's shell, file and GitHub tools away from the `java-spring` agent, where
  its smoke test verifies it) and has no permission rules, so the starter denies every permission request. The
  model works from the article text alone, which leaves a prompt hidden in an article nothing to call.
* **The jlib-inspector agent logs through `java.util.logging`.** Spring Boot bridges that to Logback, so the
  Deployment quiets it with two variables: `LOGGING_LEVEL_IO_GITHUB_BRUNOBORGES_JLIB_AGENT=WARN` and, for its JVM
  flag listing, `LOGGING_LEVEL_IO_GITHUB_BRUNOBORGES_JLIB_AGENT_JVM="OFF"`. The value is quoted because YAML 1.1
  reads a bare `OFF` as a boolean. About 30 lines still appear at start-up, before Spring takes over the logging.
* **Whether the app reports telemetry is the Pod's decision.** On `java-25-jlib` an app without `JLIB_SERVER_URL`
  and `OTEL_EXPORTER_OTLP_ENDPOINT` only gets a report printed when the JVM exits. The Deployment sets both, plus
  `OTEL_SERVICE_NAME` and the Kubernetes attributes of the Pod, so that the data is attributable. The same
  `OTEL_*` variables point the app's own [traces and metrics](#telemetry) at Aspire.
* The container's root filesystem is read-only; Tomcat's work directory is `/tmp`, an `emptyDir` in the Pod.
