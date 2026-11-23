# DevRel kit

Everything you need to present this project: a **10-minute demo**, a **90-minute workshop** and a
bank of **blog and video ideas**. All of it runs from this repository on a laptop.

| Format | Length | For | Needs |
|--------|--------|-----|-------|
| [Demo script](demo-script.md) | 10 minutes | A conference talk, a meetup, a screen recording | The platform up and the agents deployed beforehand |
| [Workshop](workshop.md) | 90 minutes | Hands-on, 10 to 30 people on their own laptops | The tools of the [quickstart](../quickstart.md) and, for one lab, a GitHub account with Copilot |
| [Blog and video ideas](content-ideas.md) | - | Writers and creators | Whatever the idea in question needs |

## The story in three sentences

Brewlet turns the language runtime into something the platform owns, so a Copilot agent splits into
three pieces with three owners. **Ops** approves, patches and rotates a plain runtime (`java-25`,
`node-24`, `python-3.13`, `dotnet-10`) that knows nothing about any framework. **Developers** ship an
artifact that is only the agent: its code, all of its libraries and a `launch.json`. The **Copilot CLI**
is a sidecar, one image for every language, and the only place the GitHub credentials live.

## Three claims, and the proof for each

Say a claim, then show the proof. Every proof is one command.

| Claim | Proof | What the audience sees |
|-------|-------|------------------------|
| **Ops owns the runtime, and patching it moves every agent.** | `make rotate` | The JDK reported by three Java frameworks changes. The artifact digests next to them do not. Nothing was rebuilt. |
| **An agent is just its own bytes.** | `make layers AGENT=node-fastify`, `cat agents/node-fastify/launch.json` | A few MiB of code and libraries, and a `launch.json` of a few hundred bytes. No interpreter, no Copilot CLI. |
| **The CLI is a sidecar, and only it has the token.** | `make inspect AGENT=java-spring` | `COPILOT_GITHUB_TOKEN` is injected into `copilot-cli` and into no other container. |

A fourth, softer one comes for free: **the frameworks are interchangeable.** All eight agents answer to
the same [contract](../contract.md), so `make ask` works unchanged for Spring Boot, Quarkus,
Micronaut, NestJS, Fastify, FastAPI, Django and ASP.NET Core.

## What to say when asked

| Question | Short answer | Where it comes from |
|----------|--------------|---------------------|
| "Why not put the dependencies in the runtime?" | A runtime id is a promise to every application on it. Framework libraries would make every upgrade an Ops change and every Ops change a risk for every application. | [Design](../design.md#1-a-fat-runtime-that-contains-the-framework-dependencies) |
| "Does rotating the runtime patch my libraries?" | No, and Brewlet says so itself. A CVE in Jackson or `node_modules` lives under `/app`, so it needs a rebuild of the artifact. The split makes that boundary visible. | [Design](../design.md#operational-trade-offs) |
| "Is that a sandbox?" | No. It is runc isolation with a locked-down Pod: non-root, no capabilities, a read-only root filesystem. Not a boundary for hostile tenants. | [Security model](../security.md) |
| "Why a CLI per Pod?" | It keeps the trust boundary at the Pod, and a shared CLI would hold every team's credentials and conversations. It costs tens of MiB per Pod. | [Design](../design.md#3-one-copilot-cli-service-for-the-whole-cluster) |
| "Can the model do anything it likes?" | It can call one tool, `runtime_facts`, and nothing else: not the CLI's own tools, not GitHub, not the web. | [Security model](../security.md) |
| "Is this production ready?" | No. The cluster runs locally with a plain-HTTP registry and no ingress. | [Design](../design.md#why-kind-and-what-is-not-in-scope) |

## Before you present

Do these the day before, on the machine you will present from, on the network you will present on.

1. `make doctor`, then `make up`: the slow, network-bound part. It pulls the runtime images and
   installs the first runtime.
2. `make agents`: builds and deploys all eight agents. It warms the Maven, npm, uv and NuGet caches
   and the registry, so a live `make agent` takes well under a minute.
3. `make auth`, then `make ask AGENT=java-spring Q="Which JDK are you on?"`. If this answers, the
   model path works end to end.
4. `make footprint`: note the numbers on **your** machine and quote those, not the ones in these pages.
5. Rehearse once with a stopwatch. The [demo script](demo-script.md) lists a fallback for every step.
6. Set the terminal font to at least 18 pt, and keep `docs/index.md` rendered (`make docs-serve`)
   in a second window: its diagram is the one slide you need.

!!! tip "Keep it offline-proof"
    Everything the demo needs is local once `make agents` has run, **except the model**. If the
    network might fail, record the `make ask` answers beforehand and keep them as a fallback; the
    `make whoami` and `make inspect` parts need no network and no credentials.

After the session:

```bash
make deauth     # take your GitHub token out of the cluster
make down       # optional: delete the cluster and the registry
```

## What not to claim

* **That rotation fixes everything.** It updates the language runtime, not what the artifact bundles.
* **That this is a production pattern.** It is a pattern, demonstrated on a laptop.
* **That the memory numbers are universal.** They come from one machine and one run. Measure your own
  with `make footprint`.
* **That the integrations are published.** They are built from a pinned commit of
  [`brunoborges/copilot-sdk-integrations`](https://github.com/brunoborges/copilot-sdk-integrations);
  see [Design](../design.md).
