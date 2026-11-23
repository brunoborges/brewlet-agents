# Design

## The question

Brewlet lets the Ops team own the language runtime. A Copilot agent has more than a language runtime in
it, though: it has the Copilot SDK, a framework integration, the framework itself, and the Copilot CLI
that the SDK drives. Which of those belong to Ops, which to developers, and which to nobody?

## The decision

Three pieces, three owners, and nothing shared between them except the contract:

| Piece | Owner | Contents | Changes when |
|-------|-------|----------|--------------|
| **Runtime** | Ops | `java-25`, `node-24`, `python-3.13` or `dotnet-10`: a plain language image, pinned by digest. **No framework, no Copilot SDK.** | Ops patches the language runtime (a JDK security update, a new Node.js 24 patch). |
| **Application artifact** | Developers | The agent's code, **all** of its dependencies (Copilot SDK, framework integration, framework) and a Brewlet `launch.json`. Nothing else. | The agent's code or libraries change. |
| **Copilot CLI sidecar** | Platform | One image, `copilot-cli`, in every Pod. Headless on loopback, token-protected, the only holder of GitHub credentials. | The CLI releases a new version. |

The same shape is used for Java, Node.js, Python and .NET. Only the runtime image and the
`build.sh` that fills the artifact differ.

## Alternatives that were rejected

### 1. A fat runtime that contains the framework dependencies

The first design considered was a `java-25-copilot` runtime: JDK 25, the Copilot SDK, and the
Spring, Quarkus and Micronaut integrations, so that an agent could be "just its logic".

It does not scale, for a structural reason. A Brewlet runtime id is a compatibility promise: every
application that selects `java-25` must keep working when Ops rotates it. The moment the runtime
contains framework libraries, that promise covers every application's *dependency graph*:

* Spring, Quarkus and Micronaut would need their libraries merged in one image, and their transitive
  dependencies (Jackson, SLF4J, Netty, and so on) agree on versions only by luck.
* Every framework upgrade becomes an Ops change and every Ops change a potential break for every
  application on that runtime.
* Node.js, Python and .NET repeat the problem with `node_modules`, site-packages and assemblies, none
  of which are designed to be shared between applications.

A framework-agnostic runtime avoids all of it: it can only break an application through the language
runtime itself, which is exactly what Ops should own.

### 2. The Copilot CLI inside the application artifact

The Copilot SDKs drive an out-of-process Copilot CLI. Packaging it in the artifact makes every agent
self-contained, and it has two costs:

* **Credentials in every agent container.** Whatever process serves HTTP also holds a GitHub token.
* **A CLI update means rebuilding every agent**, in four languages, to change something no agent
  depends on beyond a wire protocol.

As a sidecar the CLI is one image and one place for credentials. The agents see only a loopback address
and a shared connection token.

### 3. One Copilot CLI service for the whole cluster

A single shared CLI would use less memory than eight copies. In the current `make footprint` snapshot
after one request, each sidecar used 36–47 MiB (see the [measured agent footprints](agents/index.md#a-measured-snapshot)).
It also makes one process the holder of credentials for every team's conversations, over a network
connection that needs its own authentication, and it couples every agent's availability to it. The
sidecar keeps the trust boundary at the Pod, which is the unit Kubernetes already isolates.

## Operational trade-offs

* **Rotation does not patch what the artifact bundles.** Brewlet rotates the *runtime*. A CVE in
  Jackson, Netty or `node_modules` lives under `/app`, so it needs an artifact rebuild. The split
  makes this boundary visible rather than removing it.
* **Every Pod carries a CLI.** Eight agents are eight CLI processes. That is the price of the
  Pod-level trust boundary; in the current snapshot each sidecar used 36–47 MiB after one request.
* **The CLI version is the platform's choice.** An agent cannot pin its own, and the SDK and CLI have
  to stay compatible. `/runtime` reports the CLI's version and protocol so a mismatch is visible.
* **The integrations are built from a commit.** `brunoborges/copilot-sdk-integrations` is not
  published to package registries yet, so `INTEGRATIONS_SHA` in `versions.env` pins one commit and
  `scripts/integrations-build.sh` builds it locally. Moving to published packages later changes how
  each agent's `build.sh` obtains the integrations, and nothing about what is deployed.

## Why a "Runtime Concierge"

Eight agents in eight frameworks are only comparable if they do the same thing. The Runtime Concierge
is the smallest agent that makes the architecture *observable*: it has one tool that reads the live
process, so asking it "which JDK are you on, and where is your code?" is a demonstration rather than a
claim. It also exercises everything a real agent needs (a system prompt as a file resource, a custom
tool, sessions, external configuration, health checks) without an application domain that would
distract from the platform. The [contract](contract.md) is identical for every framework, and
`scripts/agent-smoke.sh` is its executable form.

## Why kind, and what is not in scope

Brewlet supports `kind`, so the cluster can run locally on Docker. This configuration has no
ingress, TLS or multi-node scheduling. The registry uses plain HTTP on the Docker network.
For the protections that apply inside each Pod, see the [security model](security.md).
