# Blog and video ideas

Ideas that this repository can back with a command, ordered from the most to the least self-contained.
Every one of them has a proof you can run on camera or paste into a post; none needs a slide to be
believable.

## Blog posts

| Working title | The angle | The proof in this repository |
|---------------|-----------|------------------------------|
| **Patching the JDK under three Java frameworks without rebuilding any of them** | Ops rotates a runtime; Spring, Quarkus and Micronaut agents move to the new JDK and their artifact digests do not change. | `make rotate`. The [rotation page](../rotation.md). |
| **`built-in-tools: false` does not lock down a Copilot agent** | Turning off the CLI's built-in tools leaves its GitHub MCP server and `web_search` callable. An allow-list is what works. | `make smoke` asks the model to list its tools and fails on anything but `runtime_facts`. [Security model](../security.md). |
| **Why the Copilot CLI is a sidecar and not part of your image** | Credentials in one container, one image for four languages, a CLI update that rebuilds nothing. | `make inspect`; the [design page](../design.md). |
| **Your agent is a few MiB: what an artifact looks like when the runtime is not in it** | Layers, `launch.json`, and what a code change costs. | `make layers`; the prompt edit in the [workshop](workshop.md#lab-4-change-the-agent). |
| **Reproducible OCI layers: why they changed when nothing did** | File modification times leaked into layer digests, so every rebuild was a new artifact until the build normalized them. | `package_artifact` in `scripts/lib/artifact.sh`; rebuild twice and compare `make layers`. |
| **One contract, eight frameworks** | How to compare Spring, Quarkus, Micronaut, NestJS, Fastify, FastAPI, Django and ASP.NET Core fairly: the same agent, the same endpoints, the same prompt, one executable contract. | [Contract](../contract.md); `make smoke`. |
| **Building Linux artifacts on a Mac** | The traps: a native macOS jar in a Linux artifact, `npm` and `uv` platform flags, .NET runtime identifiers. | The `build.sh` of each agent; the [agents overview](../agents/index.md). |
| **From zero to a Copilot agent on Kubernetes in six commands** | The quickstart as a narrative. | [Quickstart](../quickstart.md). |

### A five-part series

For a publication that wants a series, this order builds the argument:

1. **The idea.** Three owners for an agent: runtime, artifact, CLI. The diagram of the
   [home page](../index.md), and `make inspect`.
2. **The platform.** kind, Brewlet and the four runtimes: `make up`, and what `RuntimeImage` is.
3. **The agent.** One Concierge, eight frameworks. One post per language family: Java, then Node.js,
   then Python and .NET.
4. **The security.** The credential boundary, the Pod's settings and the allow-list.
5. **Patch day.** Rotation, with its limits stated first.

## Videos

| Format | Length | Outline |
|--------|--------|---------|
| **The idea** | 3 min | The three owners on one diagram, then `make inspect` on a running Pod. |
| **The demo** | 10 min | The [demo script](demo-script.md), recorded in one take. |
| **Eight frameworks, one agent** | 20 min | Build the same agent in two or three frameworks, side by side. Show the code that differs and the contract that does not. |
| **Workshop recording** | 90 min | The [workshop](workshop.md), with the instructor's commentary. |
| **Shorts** | 30 to 60 s | One command and one sentence each, from the list below. |

Short clips that stand alone:

* `make rotate`: three frameworks, one JDK patch, unchanged digests.
* "Try to break the agent": the prompt-injection question, then the refusal naming its one tool.
* "A 16 KiB deployment": edit the prompt, `make agent`, and `make layers` showing one layer changed.
* "Who has the token?": `make inspect`, last line.
* "The runtime is not in the image": `make layers AGENT=node-fastify`, then `cat launch.json`.

## A conference talk

**Title:** The runtime is not in your image: Copilot agents on Brewlet

**Abstract (about 120 words).** Containers made applications self-contained, and that is why a JDK
patch means rebuilding every service. Brewlet moves the language runtime out of the application and
into the platform, where Ops approves, patches and rotates it. We take that idea and apply it to
something new: GitHub Copilot agents. We split an agent into a runtime that Ops owns, an artifact that
holds only the agent's code and libraries, and a Copilot CLI sidecar that alone holds the credentials.
Then we do it in Spring, Quarkus, Micronaut, NestJS, Fastify, FastAPI, Django and ASP.NET Core on a
local kind cluster, change the runtime underneath them live, and say, honestly, what that does and does
not fix.

**Takeaways**

* Who should own which piece of an agent, and why.
* How to read a Brewlet artifact and a `RuntimeImage`.
* What a runtime rotation changes, and the class of vulnerability it leaves to you.
* A tool allow-list is the control that works; switching the built-ins off is not.

**Audience.** Platform engineers and developers who ship services on Kubernetes. Intermediate.
**Needs.** A projector, a laptop with the platform up, and a network for the model call (a recorded
fallback is in the [demo script](demo-script.md)).

## Social posts

Hooks that are true to the repository:

* "I patched the JDK under three Java frameworks with one command. None of them was rebuilt."
* "I asked my Copilot agent to run `id` and read `/etc/passwd`. It told me its only tool."
* "The Copilot CLI turned out to have a GitHub MCP server that `built-in-tools: false` does not turn
  off."
* "Changing my agent's prompt changed one 16 KiB layer. The other 27.7 MiB stayed put."

## Artwork

* **Java.** Use the Duke mascot for Java covers and thumbnails, not the Java logo, which is a
  trademark.
* **Diagrams.** The three-owners diagram on the [home page](../index.md) is Mermaid, so it can be edited
  as text. For a slide, take a screenshot of the rendered page at a large size.
* **Terminal captures.** Use a font size of 18 pt or more, a dark theme with high contrast, and trim
  the output to the lines you are talking about; every command here prints a lot.

## Other repositories to link

| For | Link |
|-----|------|
| Brewlet itself: the runtime model, the CLI and the operator | <https://github.com/microsoft/brewlet> |
| The framework integrations the agents use | <https://github.com/brunoborges/copilot-sdk-integrations> |
| This project's source | <https://github.com/brunoborges/brewlet-agents> |
