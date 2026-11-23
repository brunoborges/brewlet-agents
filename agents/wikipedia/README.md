# Wikipedia summarizer

Paste a Wikipedia article URL into the frontend and the Spring Boot summarizer returns a summary
using its Copilot CLI sidecar. This example also shows which jars the summarizer loads: its
instrumented Java runtime reports them to `jlib-server`, and `jlib-ui` displays the inventory.
Both services belong to this example; the other agents don't need them.

## Run the example

```bash
# From the repository root:
make up                  # shared cluster, runtimes and sidecar
make auth                # needed to generate summaries, not to deploy
cd agents/wikipedia
make run                 # Aspire + jlib services first, then the summarizer and frontend
make summarize URL='https://en.wikipedia.org/wiki/Java_(programming_language)'
make dashboards          # open the frontend and dashboards on localhost
```

## Components

| App | Language | Framework | Runtime | Namespace | What it is |
| --- | --- | --- | --- | --- | --- |
| [wikipedia-summarizer](wikipedia-summarizer/README.md) | Java 25 | Spring Boot | `java-25-jlib` | `agents` | A Copilot SDK agent with a REST API: `POST /api/summaries` takes the address of a Wikipedia article and returns a summary. Has the Copilot CLI sidecar. |
| [wikipedia-frontend](wikipedia-frontend/README.md) | Node.js 24 | Node.js | `node-24` | `agents` | A page and a small proxy in front of the summarizer. No dependencies. |
| [jlib-server](jlib-server/README.md) | Java 25 | JDK `HttpServer` | `java-25` | `observability` | The collection server of [jlib-inspector](https://github.com/brunoborges/jlib-inspector): which jars each Java application loads. |
| [jlib-ui](jlib-ui/README.md) | Node.js 24 | Express | `node-24` | `observability` | The jlib-inspector dashboard. |

The summarizer runs on a runtime that Ops extended with the jlib-inspector agent, and reports to the
jlib-server and to the Aspire OpenTelemetry dashboard. [Observability and dashboards](../../docs/observability.md)
describes that stack and how to open each dashboard, including the Brewlet dashboard.

The derived runtime's [Dockerfile](java-25-jlib/Dockerfile) and the telemetry stack's
[manifest](observability/otel-dashboard.yaml) live here. Runtime approval and credentials still
use the shared platform.

## How an app differs from an agent

| | Agent (`agents/<name>`) | App (`agents/wikipedia/<name>`) |
| --- | --- | --- |
| Description | `agent.env` | `app.env` |
| Contract | The [Runtime Concierge](../README.md): `/healthz`, `/readyz`, `/runtime`, `POST /ask` | None. It has to answer `HEALTH_PATH` with `200` on `SERVICE_PORT`. |
| Namespace | `agents` | `NAMESPACE`, `agents` when unset |
| Container | `agent` | `app` |
| Copilot CLI sidecar | Always | Only with `SIDECAR=copilot-cli`, and then in the `agents` namespace, where its Secret lives |
| Copilot SDK integration | Built from the pinned commit, for its language | Only with `INTEGRATIONS=<language>` |
| Checked by | `scripts/workloads/smoke.sh`, the executable contract | `scripts/workloads/app-smoke.sh`: the health path, then the app's own `smoke.sh` |

What is the same: the artifact (layers in a `layers` file, plus `launch.json`, with no interpreter in it), the
build, publish, deploy and rotation scripts, and the hardening every Pod gets: non-root, a read-only root
filesystem, all capabilities dropped, no privilege escalation, the default seccomp profile, no service account
token, memory requests and limits, and an artifact pinned by digest, in a namespace that enforces the `restricted`
Pod Security Standard. `make check` verifies the manifest of every app.

## What is in an app's directory

```text
agents/wikipedia/<name>/
  app.env           APP_NAME, LANGUAGE, FRAMEWORK, RUNTIME, and optionally NAMESPACE, SERVICE_PORT, HEALTH_PATH, SIDECAR, INTEGRATIONS
  Makefile          make run: build, publish, deploy and smoke-test this app
  build.sh          directly runnable: stages the app, runs its build checks and packages its Brewlet artifact
  layers            one Brewlet layer per line: <directory under the build output>:<path inside /app>
  launch.json       how Brewlet starts it: entrypoint, arguments, working directory, environment, runtime id
  deployment.yaml   the complete Deployment, Service and ServiceAccount
  smoke.sh          the app's own checks, run against the deployed Service
  README.md         what it is, what is in the artifact, how to run it, what to watch for
```

| `app.env` key | Meaning |
| --- | --- |
| `APP_NAME` | The component directory name. Names are unique across agents and apps. |
| `LANGUAGE` | `java`, `node`, `python` or `dotnet` |
| `FRAMEWORK` | Free text, shown by `make list` |
| `RUNTIME` | The Brewlet runtime id from `runtimes/`, for example `java-25` or `node-24` |
| `NAMESPACE` | Where it is deployed (`agents` when unset) |
| `SERVICE_PORT`, `HEALTH_PATH` | The Service's port (`80`) and the health path the smoke test and the manifest check use (`/healthz`) |
| `SIDECAR` | `copilot-cli` for an app that talks to Copilot |
| `INTEGRATIONS` | The language of the Copilot SDK integration the build needs (`build.sh` receives it in `$INTEGRATIONS_OUT`) |

## Build, run, inspect

From the **repository root**, the `make` targets that take `AGENT=<name>` take `APP=<name>` as well:

```bash
make build APP=wikipedia-summarizer      # test and package the artifact
make publish APP=wikipedia-summarizer    # push it to the local registry and verify it
make deploy APP=wikipedia-summarizer     # the Pod, on the Brewlet runtime
make smoke APP=wikipedia-summarizer      # the app's own checks through a port-forward
make agent APP=wikipedia-summarizer      # the four steps above
make layers APP=jlib-ui                  # what the artifact is made of
make footprint                           # size and memory of everything deployed
make logs APP=wikipedia-summarizer       # the app's log and its sidecar's
make undeploy APP=wikipedia-summarizer
make list                                # agents and apps, with language and runtime
```

`make wikipedia` builds and deploys the summarizer and its front-end; `make observability` does the same for
the jlib-inspector server and UI, after it deploys the Aspire dashboard. `make agents` is for the eight agents.

## Adding an app

1. Copy the closest app, and change `app.env`, `launch.json`, `layers`, `build.sh`, `deployment.yaml` and `smoke.sh`.
2. Write its `README.md`, add `docs/apps/<name>.md` (a one-line stub, `<!-- source: agents/wikipedia/<name>/README.md -->`, like
   its siblings) and add it to the `nav` of `mkdocs.yml`.
3. Run `make check`: it needs neither a cluster nor Docker, and it checks the files above, the manifest (name,
   namespace, runtime, health path, Service port, sidecar, hardening, pinned image) and the documentation wiring.
4. Run `make agent APP=<name>` against a cluster.
