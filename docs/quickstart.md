# Quickstart

From nothing to a Copilot agent running on a Brewlet runtime in your own kind cluster.

## What you need

| Tool | Why |
|------|-----|
| Docker | Runs the kind node, the local registry and the image builds. Give it at least 4 GiB of memory. |
| `kind`, `kubectl`, `helm` | Cluster, client, and the Brewlet chart. |
| `jq`, `curl`, `openssl` | Used by the scripts. |
| A language toolchain per agent or app | Java 25 for the Java agents and the Wikipedia summarizer, Node.js 24 (and `git`, for the jlib-inspector dashboard) for Node.js, `uv` for Python, the .NET 10 SDK for .NET. You only need the ones for what you build. |

`make doctor` checks all of this and tells you what is missing. The Maven Wrapper that ships with
the integrations is used when you do not have Maven.

!!! note "Apple silicon and Intel"
    The scripts build for the architecture of your Docker daemon (`arm64` or `amd64`) and pin the
    matching Copilot CLI checksum. Nothing in the agents is architecture-specific.

## 1. The platform, once

```bash
make up
```

`make up` is three steps, each of which you can run on its own:

| Step | What happens |
|------|--------------|
| `make cluster` | Creates the kind cluster `brewlet-agents` and a local registry on `localhost:5001`, installs Brewlet (the Helm chart and the node provisioner) and the `agents` namespace, and enables [rotation restarts](rotation.md) for it. |
| `make runtimes` | Registers and approves the Ops-owned runtimes from [`runtimes/`](https://github.com/brunoborges/brewlet-agents/tree/main/runtimes): `java-25`, `node-24`, `python-3.13`, `dotnet-10`, and `java-25-jlib`, which is `java-25` with the [jlib-inspector](observability.md#the-java-25-jlib-runtime) agent that this step builds and pushes to the local registry first. Each is pinned by digest. |
| `make sidecar` | Builds the Copilot CLI sidecar image (checksum-verified download of the pinned CLI release onto a distroless base) and pushes it to the local registry. |

The first run downloads several images and installs the first runtime, which is the slow part and
depends on your network. The cluster reports `lstat /run/brewlet: no such file or directory` while
that happens; see [Troubleshooting](troubleshooting.md#the-first-runtime-install-prints-an-lstat-error).

## 2. Your first agent

```bash
make agent AGENT=java-spring
```

That runs four targets in a row, and each one is also available on its own:

| Target | What it does |
|--------|--------------|
| `make build` | Builds the integrations (once), then the agent's OCI artifact: code, **all** libraries, `launch.json`. |
| `make publish` | Pushes it to the local registry and records the digest. |
| `make deploy` | Applies the agent's `deployment.yaml`. The agent container is pinned to that digest. |
| `make smoke` | Runs the contract checks through a port-forward. |

Then look at what is running:

```bash
make status
make whoami AGENT=java-spring
```

`make whoami` prints the agent's `/runtime` document. It works without any credentials, because it
does not call a model. Look at the two paths: the agent's own location is under `/app` (the artifact
you pushed), and the language home is under `/usr/jdk` (the runtime Ops owns).

## 3. Let it talk to the model

The agents are useless without a model, and the model needs a GitHub identity. That is opt-in:

```bash
make auth
make ask AGENT=java-spring Q="Which JDK are you running on, and where does your code live?"
```

`make auth` stores your GitHub token in a Kubernetes Secret that only the Copilot CLI sidecar can
read. It uses `$COPILOT_GITHUB_TOKEN` when that is set, and `gh auth token --hostname github.com` otherwise:

```bash
export COPILOT_GITHUB_TOKEN="$(gh auth token --hostname github.com)"
make auth
```

[GitHub authentication](authentication.md) explains what it stores, which tokens work, and how
to remove it (`make deauth`).

## 4. The other frameworks

```bash
make list           # the eight agents and the four apps, with their runtimes
make agents         # build, deploy and smoke-test all of them
make agent AGENT=node-fastify
```

Every agent exposes the same four endpoints, so the commands above work unchanged for each of them.
The [agents overview](agents/index.md) compares them.

## 5. The part that Brewlet is for

```bash
make rotate
```

Ops patches the `java-25` runtime. The three Java agents restart on the new JDK; nothing is rebuilt
and the artifact digests do not change. The [rotation demo](rotation.md) walks through it.

## 6. The Wikipedia summarizer and the dashboards

The [apps](apps/index.md) are workloads that do not follow the Runtime Concierge contract. The first is a Spring
Boot agent with a REST API that summarizes a Wikipedia article; the others are a Node.js front-end for it and the
stack that watches it run. The summarizer talks to the model, so do step 3 first.

```bash
make observability
make wikipedia
make summarize URL='https://en.wikipedia.org/wiki/Java_(programming_language)'
make dashboards
```

| Target | What it does |
|--------|--------------|
| `make observability` | Deploys the Aspire OpenTelemetry dashboard, and the jlib-inspector server and dashboard, into the `observability` namespace. |
| `make wikipedia` | Builds, publishes, deploys and smoke-tests the summarizer and its front-end. The summarizer runs on `java-25-jlib`, so the agent in that runtime reports what it loads. |
| `make summarize` | Posts the article's address to the summarizer's REST API and prints the summary. `VIA=frontend` goes through the front-end. |
| `make telemetry` | Checks that the agent's report reached the jlib-inspector server, and that logs, traces and metrics reached the Aspire dashboard. |
| `make dashboards` | Forwards the Brewlet, jlib-inspector and OpenTelemetry dashboards and the front-end to your machine, and prints what each one needs to sign in. |

[Observability and dashboards](observability.md) describes what each dashboard shows. The
[Wikipedia summarizer](apps/wikipedia-summarizer.md) page has its API.

## Clean up

```bash
make deauth      # remove the GitHub token from the cluster
make down        # delete the cluster and the registry
```

`make clean` removes build output and keeps the cluster.

## Documentation, offline

```bash
make docs-serve
```

serves this site on <http://127.0.0.1:8000>. It uses `mkdocs` when it is installed and the pinned
`squidfunk/mkdocs-material` image otherwise.
