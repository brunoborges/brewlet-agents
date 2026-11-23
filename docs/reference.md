# Reference

## Make targets

`make help` prints this list from the Makefile. `AGENT` is one of the agents and `APP` one of the apps that
`make list` prints; the per-workload targets take either, because each workload has a unique name.

### The platform, once

| Target | What it does |
|--------|--------------|
| `make doctor` | Checks the host tools and the cluster. |
| `make up` | `cluster`, `runtimes` and `sidecar`. |
| `make cluster` | Creates the kind cluster, the local registry and installs Brewlet with its dashboard. Safe to rerun. |
| `make runtimes` | Registers and approves the five runtimes in `runtimes/`, building the derived `java-25-jlib` first. |
| `make sidecar` | Builds and pushes the Copilot CLI sidecar. |
| `make down` | Deletes the cluster and the registry. |

### One agent or app

| Target | What it does |
|--------|--------------|
| `make build AGENT=…` | Builds the OCI artifact into a local store. |
| `make publish AGENT=…` | Pushes the artifact, verifies it and records its digest. |
| `make layers AGENT=…` | Shows the pushed artifact's layers and their compressed sizes. |
| `make footprint [AGENT=…]` | The artifact size and the memory each container of the deployed agents and apps uses right now. |
| `make deploy AGENT=…` | Applies the `deployment.yaml` with its images pinned to the published digests. |
| `make smoke AGENT=…` | The checks, through a port-forward: the contract for an agent, `scripts/workloads/app-smoke.sh` for an app. `REQUIRE_AUTH=1` makes the live model call mandatory. |
| `make agent AGENT=…` | The four above, in order. |
| `make undeploy AGENT=…` | Removes it from the cluster. |
| `make logs AGENT=…` | Its recent logs, and its sidecar's. |
| `make whoami AGENT=…` | The agent's `/runtime` document. No credentials needed. |
| `make inspect AGENT=…` | How the Pod is put together: the runtime, the artifact, the sidecar and which container receives which variable (names only, never values). |
| `make ask AGENT=… Q="…"` | Asks the agent a question. Needs `make auth`. |

### The Wikipedia summarizer and the dashboards

| Target | What it does |
|--------|--------------|
| `make observability` | Deploys the Aspire OpenTelemetry dashboard, jlib-server and jlib-ui into the `observability` namespace. |
| `make wikipedia` | `make agent` for the summarizer and the front-end. |
| `make summarize URL=… [VIA=frontend]` | Summarizes a Wikipedia article through the REST API, or through the front-end. Needs `make auth`. |
| `make telemetry` | Reads the data back from jlib-server and Aspire to show that the agent's report, and the app's logs, traces and metrics, arrived. |
| `make dashboards [DASHBOARDS="brewlet jlib otel frontend"]` | Forwards the dashboards to `127.0.0.1` until Ctrl-C and prints each one's sign-in. |

### All agents and day two

| Target | What it does |
|--------|--------------|
| `make list` | The agents and apps with their language, framework and runtime. |
| `make agents` | `make agent` for every agent, one after the other. |
| `make build-all` | Builds and publishes every agent and app without deploying. |
| `make status` | Pods in `agents` and `observability`, and the Brewlet `RuntimeImage`s. |
| `make auth` / `make deauth` | Store / remove the GitHub token for the sidecar. |
| `make rotate` | The [rotation demo](rotation.md). |
| `make rotate-status` | The JDK each Java agent runs on, next to its artifact digest. |
| `make check` | The static checks (see below). No cluster needed. |
| `make docs` / `make docs-serve` | Build / serve this site. |
| `make clean` | Removes build output, keeps the cluster. |

## Static checks

`make check` runs `scripts/checks/repository.sh`, which CI runs too. It needs no cluster and verifies that:

* `versions.env` and the runtime catalog are complete;
* every agent has a valid `agent.env`, a `launch.json` that lists its runtime, a system prompt
  identical to the reference one, and a `deployment.yaml` that agrees with `agent.env` and `versions.env`;
* every app has a valid `app.env`, executable `build.sh` and `smoke.sh`, a `launch.json` and `layers`, and a
  `deployment.yaml` that is exactly a Deployment, a Service and a ServiceAccount, hardened, with an artifact pinned
  by digest; an app with a Copilot CLI sidecar gets the connection token from the Secret; an app on `java-25-jlib`
  reports to the jlib-inspector server and to the OpenTelemetry endpoint, mounts only the `connection-token` key
  of the Secret, and has no environment variable that comes from a Secret or is named like a credential
  ([why](security.md#the-observability-stack));
* every agent and app has a README and a docs page that renders it, and `mkdocs.yml` lists them;
* every workflow parses, every script passes `bash -n` and, where ShellCheck is installed, ShellCheck;
* the documentation toolchain pin in `docs/requirements.txt` matches `versions.env`, and every page
  in the `mkdocs.yml` navigation exists;
* no file contains a token.

## Scripts

Start in `agents/<name>/` or `agents/wikipedia/<name>/`. Run `./build.sh` to package that example, or
`make run` to build, publish, deploy and smoke-test it against the shared platform. The local
`Makefile` shows the commands in order; the root `make agent` target runs the same recipe.

| Shared scripts | Purpose |
|----------------|---------|
| `scripts/platform/` | Cluster setup and teardown, runtime approval and rotation, the sidecar and its credentials. |
| `scripts/integrations/` | Build the pinned Copilot SDK integrations for each language. |
| `scripts/workloads/` | Publish and verify an artifact, pin and deploy a manifest, and interact with the deployed workload. |
| `agents/wikipedia/observability/` | Deploy the telemetry stack, verify telemetry and open the dashboards. |
| `scripts/demos/` | Run the runtime rotation example. |
| `scripts/checks/` | Check the repository and host tools. |
| `scripts/lib/` | Sourced Bash helpers for artifact packaging, cluster access and HTTP checks. |

## Runtimes

`runtimes/<id>.env` is the catalog Ops approves. Each file pins an image **by digest** and declares the
interpreter and the user id the runtime uses. The agents' `launch.json` reference the interpreter by
absolute path.

| Runtime id | Image | Interpreter |
|------------|-------|-------------|
| `java-25` | `mcr.microsoft.com/openjdk/jdk:25-distroless` | `/usr/jdk/bin/java` |
| `java-25-jlib` | `java-25` plus the jlib-inspector agent, built by `scripts/platform/runtime-build.sh` and pushed to the local registry | `/usr/jdk/bin/java` |
| `node-24` | `gcr.io/distroless/nodejs24-debian13` | `/nodejs/bin/node` |
| `python-3.13` | `gcr.io/distroless/python3-debian13` | `/usr/bin/python3` |
| `dotnet-10` | `mcr.microsoft.com/dotnet/aspnet:10.0-azurelinux3.0-distroless` | `/usr/bin/dotnet` |

`java-25-jlib` is a **derived** runtime: its file names `BASE=java-25` and the directory to build, instead of an image.
[Observability and dashboards](observability.md#the-java-25-jlib-runtime) explains how it is built and approved.

## Pinned versions

[`versions.env`](https://github.com/brunoborges/brewlet-agents/blob/main/versions.env) is the single
source of truth. It pins Brewlet and its chart, the Copilot CLI and its SHA-256 checksums, the Copilot
SDK of each language, the `copilot-sdk-integrations` commit, the sidecar's base images, jlib-inspector
(the release, its two jars' SHA-256 checksums and the commit its dashboard is built from), the Aspire dashboard image and the
documentation toolchain. Raising a version there is how the platform is upgraded.

## The agent contract

The endpoints, error codes, environment variables and the layout of an agent directory are on the
[Runtime Concierge contract](contract.md) page.
