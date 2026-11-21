# Security model

This is a laptop demo, and it is honest about that. What follows is what the project does enforce,
what it deliberately does not, and what you would change before running anything like it for real.

## What is enforced

### The credential boundary

| Credential | Held by | Reaches the agent container? |
|------------|---------|------------------------------|
| GitHub token (`COPILOT_GITHUB_TOKEN`) | The `copilot-cli` sidecar only | **No** |
| Connection token (`COPILOT_CONNECTION_TOKEN`) | Sidecar and agent | Yes, it is the agent's way in |

The Copilot CLI refuses to start without a connection token, and the SDK must present it on every
connection. The containers of a Pod share a network namespace, so loopback on its own would be open
to any process in the Pod; the token is what makes the sidecar an authenticated service. It is a
random 256-bit value generated per cluster and is not a GitHub credential. See
[GitHub authentication](authentication.md) for the token types and `make deauth`.

### What the agent can do

* **One tool.** An agent exposes `runtime_facts` to the model and nothing else, and the SDK permission
  handler allows only that tool. A prompt injection through a question therefore reaches a function that
  returns facts about the process.
* **An allow-list, not a deny-list.** Switching off the Copilot CLI's built-in tools (shell, file system)
  is not enough. The CLI brings tools of its own, among them the GitHub MCP server, which can read
  repositories with the sidecar's token, and `web_search`, and they stay callable. Each agent therefore
  allow-lists `custom:*`, the agent's own tools, over every tool source. `make smoke` proves it by asking
  the model to list the tools it can call, and fails on anything but `runtime_facts`.
* **No identity in the output.** `/runtime` and the tool never contain the GitHub login, a token or the
  connection token.
* **Bounded input.** Questions are limited to 4000 characters, conversation ids to a small character
  set, and the model call to two minutes.

### The Pod

Every container, the sidecar included, runs with:

* a non-root user and `runAsNonRoot`;
* a read-only root file system, with `/tmp` as the only writable path (`emptyDir`, size-limited);
* no Linux capabilities and no privilege escalation;
* the `RuntimeDefault` seccomp profile.

The `agents` namespace enforces the Pod Security **restricted** profile, so a manifest that drops
any of these is rejected. No agent mounts a service account token (`automountServiceAccountToken:
false`), because none of them calls the Kubernetes API. Nothing is exposed outside the cluster: the
Services are `ClusterIP` and the scripts use `kubectl port-forward`.

### What Brewlet adds

* **Immutable applications.** Brewlet runs only application images pinned by digest, and the shim
  verifies the content before starting it. `make publish` ends with `brewlet verify`.
* **A read-only `/app`.** The artifact is mounted read-only, world-readable, and cannot hold secrets by
  design.
* **An approved runtime.** The runtime comes from a `RuntimeImage` that Ops approved, not from the
  application, and Brewlet hides the runtime's own `/app` content instead of merging it.
* **Identity from the runtime.** Brewlet admission sets the user and group the runtime declares, and
  enforces non-root, no capabilities and no privilege escalation.

### The supply chain

| Input | How it is pinned |
|-------|------------------|
| Runtime images | By digest, in `runtimes/*.env` |
| Copilot CLI | By version and by SHA-256 of the release tarball, in `versions.env`; the sidecar build fails on a mismatch |
| Sidecar base and fetch images | By digest, in `versions.env` |
| `copilot-sdk-integrations` | By commit, `INTEGRATIONS_SHA` |
| Copilot SDK packages | By version, `COPILOT_SDK_*_VERSION` |
| Agent artifact | By digest, at deployment |
| Brewlet | By chart version, `BREWLET_VERSION` |

`make check`, which CI runs on every push, also scans the repository for token patterns.

## What is not covered

!!! warning "Not a production reference"
    * **Isolation is `runc`.** Brewlet's own documentation is explicit that this is container isolation
      and not a sandbox for hostile tenants.
    * **Rotation does not patch bundled dependencies.** A runtime rotation replaces the JDK, Node.js,
      CPython or .NET runtime. A vulnerable library under `/app` (Jackson, Netty, an npm package) needs
      a rebuilt artifact. This is the other side of the split, not a gap in it.
    * **Secrets are base64 in etcd.** The kind cluster does not encrypt Secrets at rest.
    * **The registry is plain HTTP**, on the Docker network, without authentication.
    * **No NetworkPolicy.** The sidecar needs outbound HTTPS to GitHub; the agent needs no egress at
      all, but nothing enforces that here.
    * **The token is yours.** With `make auth` the agents act as your GitHub account. Prefer a
      fine-grained token that only has **Copilot Requests**, and run `make deauth` when you are done.
    * **The model's answers are not trusted output.** The Concierge repeats what the tool returns, but
      anything the model writes should be treated as untrusted text by whatever consumes it.

## Before you adapt this for a real cluster

1. Put the registry behind TLS and authentication, and keep Brewlet's digest pinning.
2. Encrypt Secrets at rest or fetch them from an external store, and use a dedicated Copilot
   identity per environment.
3. Add a NetworkPolicy that allows the sidecar to reach GitHub and nothing else, and allows ingress
   to the agent only from its callers.
4. Set the CPU and memory requests from measurements ([agents overview](agents/index.md) has some).
5. Decide who may approve a `RuntimeImage`; in Brewlet that is the point at which Ops takes
   responsibility for a runtime.
