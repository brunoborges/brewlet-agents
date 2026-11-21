# Reference

## Make targets

`make help` prints this list from the Makefile. `AGENT` is one of the names `make list` prints.

### The platform, once

| Target | What it does |
|--------|--------------|
| `make doctor` | Checks the host tools and the cluster. |
| `make up` | `cluster`, `runtimes` and `sidecar`. |
| `make cluster` | Creates the kind cluster, the local registry and installs Brewlet. Safe to rerun. |
| `make runtimes` | Registers and approves the four runtimes in `runtimes/`. |
| `make sidecar` | Builds and pushes the Copilot CLI sidecar. |
| `make down` | Deletes the cluster and the registry. |

### One agent

| Target | What it does |
|--------|--------------|
| `make build AGENT=…` | Builds the agent's OCI artifact into a local store. |
| `make publish AGENT=…` | Pushes the artifact, verifies it and records its digest. |
| `make layers AGENT=…` | Shows the pushed artifact's layers and their compressed sizes. |
| `make footprint [AGENT=…]` | The artifact size and the memory each container of the deployed agents uses right now. |
| `make deploy AGENT=…` | Renders the manifest and applies it. |
| `make smoke AGENT=…` | The contract checks, through a port-forward. `REQUIRE_AUTH=1` makes the live model call mandatory. |
| `make agent AGENT=…` | The four above, in order. |
| `make undeploy AGENT=…` | Removes the agent from the cluster. |
| `make logs AGENT=…` | The agent's and its sidecar's recent logs. |
| `make whoami AGENT=…` | The agent's `/runtime` document. No credentials needed. |
| `make inspect AGENT=…` | How the agent's Pod is put together: the runtime, the artifact, the sidecar and which container receives which variable (names only, never values). |
| `make ask AGENT=… Q="…"` | Asks the agent a question. Needs `make auth`. |

### All agents and day two

| Target | What it does |
|--------|--------------|
| `make list` | The agents with their language, framework and runtime. |
| `make agents` | `make agent` for every agent, one after the other. |
| `make build-all` | Builds and publishes every agent without deploying. |
| `make status` | Pods in `agents` and the Brewlet `RuntimeImage`s. |
| `make auth` / `make deauth` | Store / remove the GitHub token for the sidecar. |
| `make rotate` | The [rotation demo](rotation.md). |
| `make rotate-status` | The JDK each Java agent runs on, next to its artifact digest. |
| `make check` | The static checks (see below). No cluster needed. |
| `make docs` / `make docs-serve` | Build / serve this site. |
| `make clean` | Removes build output, keeps the cluster. |

## Static checks

`make check` runs `scripts/check.sh`, which CI runs too. It needs no cluster and verifies that:

* `versions.env` and the runtime catalog are complete;
* every agent has a valid `agent.env`, a `launch.json` that lists its runtime, a system prompt
  identical to the reference one, and a manifest that renders;
* every agent has a README and a docs page that renders it, and `mkdocs.yml` lists them;
* every workflow parses, every script passes `bash -n` and, where ShellCheck is installed, ShellCheck;
* the documentation toolchain pin in `docs/requirements.txt` matches `versions.env`, and every page
  in the `mkdocs.yml` navigation exists;
* no file contains a token.

## Scripts

All of them are plain Bash (compatible with the Bash 3.2 that macOS ships) and print what they do.

| Script | Purpose |
|--------|---------|
| `lib.sh` | Shared helpers and the settings from `versions.env`. Sourced, never run. |
| `install-brewlet.sh` | Downloads the pinned Brewlet CLI into `.bin/`. |
| `cluster-up.sh`, `cluster-down.sh` | The cluster, registry and Brewlet install, and their removal. |
| `runtime-register.sh` | Approves the runtimes of `runtimes/*.env` and offers them through a `NodeProfile`. |
| `runtime-rotate.sh` | Moves a runtime to a new image digest and waits for the rotation. |
| `sidecar-build.sh` | Builds the Copilot CLI sidecar image. |
| `integrations-build.sh`, `integrations/<language>.sh`, `mvn.sh` | Build the pinned `copilot-sdk-integrations` for a language. |
| `agent-build.sh`, `agent-publish.sh` | Source to a verified, digest-addressed artifact. |
| `agent-render.sh`, `agent-deploy.sh`, `agent-undeploy.sh` | The manifest and its lifecycle. |
| `agent-smoke.sh`, `agent-ask.sh`, `agent-layers.sh`, `agent-inspect.sh`, `footprint.sh` | Talk to a deployed agent through a port-forward; show what a published artifact and a deployed Pod are made of; measure what the agents cost. |
| `copilot-auth.sh` | Stores or removes the GitHub token. |
| `demo-rotation.sh` | The rotation demo. |
| `check.sh`, `doctor.sh` | The static checks and the host check. |

## Runtimes

`runtimes/<id>.env` is the catalog Ops approves. Each file pins an image **by digest** and declares the
interpreter and the user id the runtime uses. The agents' `launch.json` reference the interpreter by
absolute path.

| Runtime id | Image | Interpreter |
|------------|-------|-------------|
| `java-25` | `mcr.microsoft.com/openjdk/jdk:25-distroless` | `/usr/jdk/bin/java` |
| `node-24` | `gcr.io/distroless/nodejs24-debian13` | `/nodejs/bin/node` |
| `python-3.13` | `gcr.io/distroless/python3-debian13` | `/usr/bin/python3` |
| `dotnet-10` | `mcr.microsoft.com/dotnet/aspnet:10.0-azurelinux3.0-distroless` | `/usr/bin/dotnet` |

## Pinned versions

[`versions.env`](https://github.com/brunoborges/brewlet-agents/blob/main/versions.env) is the single
source of truth. It pins Brewlet and its chart, the Copilot CLI and its SHA-256 checksums, the Copilot
SDK of each language, the `copilot-sdk-integrations` commit, the sidecar's base images and the
documentation toolchain. Raising a version there is how the platform is upgraded.

## The agent contract

The endpoints, error codes, environment variables and the layout of an agent directory are on the
[Runtime Concierge contract](contract.md) page.
