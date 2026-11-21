# The agents

Eight agents, one contract. Each is the same small service, the **Runtime Concierge**, written in
the idiom of its framework: it answers questions about the environment it runs in, using one tool that
reads the live process. The [contract](../contract.md) is identical for all of them and
`scripts/agent-smoke.sh` is its executable form, so a difference you see between two agents is a
difference between frameworks, not between tasks.

## At a glance

| Agent | Language | Framework | Runtime | Copilot integration |
|-------|----------|-----------|---------|---------------------|
| [java-spring](java-spring.md) | Java | Spring Boot | `java-25` | `copilot-spring-boot-starter` |
| [java-quarkus](java-quarkus.md) | Java | Quarkus | `java-25` | `copilot-quarkus` |
| [java-micronaut](java-micronaut.md) | Java | Micronaut | `java-25` | `copilot-micronaut` |
| [node-nestjs](node-nestjs.md) | TypeScript | NestJS | `node-24` | `@copilot-sdk-integrations/nestjs` |
| [node-fastify](node-fastify.md) | TypeScript | Fastify | `node-24` | `@copilot-sdk-integrations/fastify` |
| [python-fastapi](python-fastapi.md) | Python | FastAPI | `python-3.13` | `copilot-fastapi` |
| [python-django](python-django.md) | Python | Django | `python-3.13` | `copilot-django` |
| [dotnet-aspnet](dotnet-aspnet.md) | C# | ASP.NET Core | `dotnet-10` | `CopilotSdk.Extensions.Hosting` |

The integrations come from [`brunoborges/copilot-sdk-integrations`](https://github.com/brunoborges/copilot-sdk-integrations),
built from a pinned commit (see [Design](../design.md)). Under each of them sits the Copilot SDK for that
language, which talks to the Copilot CLI sidecar and never bundles it.

## What is the same

* **The Pod.** One manifest template, `deploy/agent.yaml.tmpl`, renders all eight: the agent container on
  its runtime, the Copilot CLI as a native sidecar, the same security settings and probes.
* **The artifact.** Two layers plus the launch description: `deps` (all the libraries), `code` (the
  agent's own bytes) and `launch.json`. No interpreter and no Copilot CLI.
* **The contract.** `/healthz`, `/readyz`, `/runtime`, `POST /ask`, one tool, and a system prompt that is
  a file resource, byte-for-byte the same in every agent.
* **The lockdown.** The model can call the agent's own tool and nothing else.

## What differs

| | Java | Node.js | Python | .NET |
|--|------|---------|--------|------|
| Runtime image | Microsoft Build of OpenJDK 25, distroless | distroless Node.js 24 | distroless Python 3.13 | ASP.NET 10, Azure Linux distroless |
| Entrypoint | `java -jar` | `node dist/main.js` | `python3 -m concierge` | `dotnet Concierge.dll` |
| What `deps` holds | The jars | `node_modules` | `site-packages` | The published assemblies |
| Built for Linux on a Mac by | Maven, which is platform-independent | `npm install --os=linux --cpu=… --libc=glibc` | `uv pip install --python-platform …` | `dotnet publish -r linux-<arch>` |

Each agent's own page, rendered from its `README.md`, lists the framework-specific decisions and the
traps found while building it.

## Measure them

```bash
make agents      # build, deploy and smoke-test all eight
make footprint   # artifact size, and the memory each container uses right now
make layers AGENT=<name>
```

`make footprint` reads the container runtime's own numbers from the node, so the agent and the sidecar
are measured the same way for every language.

### A measured snapshot

This snapshot is from `make footprint` after one `make ask` for each agent. Artifact size is compressed;
container memory is the current working set and varies with requests and runtime activity.

| Agent | Artifact MiB | Agent MiB | Sidecar MiB |
|-------|-------------:|----------:|------------:|
| java-spring | 27.7 | 180 | 44 |
| java-quarkus | 23.8 | 143 | 43 |
| java-micronaut | 22.8 | 150 | 47 |
| node-nestjs | 4.7 | 59 | 36 |
| node-fastify | 4.2 | 52 | 37 |
| python-django | 13.5 | 97 | 36 |
| python-fastapi | 9.5 | 96 | 38 |
| dotnet-aspnet | 6.0 | 122 | 42 |

## Add a ninth

An agent is a directory under `agents/`; `scripts/check.sh` verifies the shape and the contract without
needing a cluster. [What an agent directory contains](../contract.md#what-an-agent-directory-contains)
lists the files, and the Spring agent is the reference to copy.
