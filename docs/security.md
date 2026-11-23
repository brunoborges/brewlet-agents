# Security model

The local cluster isolates credentials at the Pod level. It is not a security boundary for hostile
tenants.

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

The agents get the connection token as an environment variable from the Secret. The
[summarizer](apps/wikipedia-summarizer.md) gets it as a file instead: it runs on the `java-25-jlib` runtime,
whose [jlib-inspector](observability.md#the-java-25-jlib-runtime) agent reports every environment variable of the
process to a server that has no authentication. The file is mounted read-only from the same Secret, holds only the
`connection-token` key, and Spring reads it as configuration (`configtree:`), so the value is neither in the
environment nor in anything the agent sends.

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

### The Wikipedia summarizer

The [summarizer](apps/wikipedia-summarizer.md) differs from the agents above in two ways: it fetches a page on
behalf of its caller, and it gives the model no tool.

* **It does not fetch the caller's URL.** It accepts an `https` address of `<language>.wikipedia.org` (or the
  mobile form) and nothing else, takes the language and the title out of it, and builds its own request to the
  MediaWiki API. That request does not follow redirects, reads at most 8 MiB and takes at most ten seconds.
  `https://example.com/wiki/Java` and `https://en.wikipedia.org.example.com/wiki/Java` are refused with a `400`.
* **The article is untrusted text.** It is placed between two marker lines with a random token that changes on every
  request, and the prompt says that what lies between them is text to summarize and never instructions. The agent
  registers no tool and has no permission rules, so a request for a tool is denied.
* **One conversation per summary.** Each summary has its own session, deleted when the answer is back, so one
  reader's article is never in another's context.

### The Pod

Every container, the sidecar included, runs with:

* a non-root user and `runAsNonRoot`;
* a read-only root file system, with `/tmp` as the only writable path (`emptyDir`, size-limited);
  the Copilot CLI unpacks itself there (about 275 MB) on every start and runs from it;
* no Linux capabilities and no privilege escalation;
* the `RuntimeDefault` seccomp profile.

The `agents` namespace enforces the Pod Security **restricted** profile, so a manifest that drops
any of these is rejected. No agent mounts a service account token (`automountServiceAccountToken:
false`), because none of them calls the Kubernetes API. Nothing is exposed outside the cluster: the
Services are `ClusterIP` and the scripts use `kubectl port-forward`. The `observability` namespace
enforces the same profile.

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
| `java-25-jlib` runtime | The `java-25` base by digest and the jlib-inspector agent jar by SHA-256, as for the others; its own digest is the one the local build produced, which Brewlet approves as it is |
| Copilot CLI | GitHub's published image by digest, `COPILOT_CLI_IMAGE`; `gh attestation verify oci://<COPILOT_CLI_IMAGE> --repo github/copilot-cli` checks its build provenance |
| Fetch image of the derived runtime and the rotation demo | By digest, `FETCH_IMAGE` |
| `copilot-sdk-integrations` | By commit, `INTEGRATIONS_SHA` |
| Copilot SDK packages | By version, `COPILOT_SDK_*_VERSION` |
| jlib-inspector agent and server jars | By release version and by SHA-256 of each jar, in `versions.env`; the build fails on a mismatch |
| jlib-inspector dashboard source | By commit, `JLIB_INSPECTOR_COMMIT`, fetched by hash and verified; its five run-time npm packages are resolved at build time within their version ranges (the project ships no lockfile) |
| OpenTelemetry dashboard | By digest, `OTEL_DASHBOARD_IMAGE` |
| Agent and app artifacts | By digest, at deployment |
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
    * **No NetworkPolicy.** The sidecar needs outbound HTTPS to GitHub; the agents need no egress at
      all, except that the summarizer reads Wikipedia, but nothing enforces that here. Nor does anything
      restrict who may reach the [observability stack](#the-observability-stack).
    * **The token is yours.** With `make auth` the agents act as your GitHub account. Prefer a
      fine-grained token that only has **Copilot Requests**, and run `make deauth` when you are done.
    * **The model's answers are not trusted output.** The Concierge repeats what the tool returns, but
      anything the model writes should be treated as untrusted text by whatever consumes it.

## The observability stack

The `observability` namespace holds the OpenTelemetry dashboard (Aspire), the jlib-inspector server and the
jlib-inspector dashboard. Its Pods run as non-root, with a read-only root file system, no capabilities, the
`RuntimeDefault` seccomp profile and no service account token, and its Services are `ClusterIP`: the way in is
`make dashboards`, a port-forward from your machine. See [Observability and dashboards](observability.md) for what
each one does. What it lacks is access control, because it is meant for a cluster that only you use:

!!! warning "Open inside the cluster"
    * **No authentication** on jlib-server and the jlib-inspector dashboard. Any Pod that can reach them can read the
      inventory and report as any application. On the dashboard it can also point the dashboard at another URL
      (`POST /api/server-config`), which makes the dashboard's Pod request that address every ten seconds until it
      restarts. The dashboard's API answers cross-origin requests from any site (CORS is open), so close the
      port-forwards when you are not using them.
    * **Unauthenticated OTLP, without TLS**, on the OpenTelemetry dashboard's ports 18889 and 18890. Any Pod can write
      telemetry to it. Reading it takes the browser token or the API key. The summarizer's own traces and metrics
      carry request paths, status codes, timings, JVM statistics, the Wikipedia host of each request and whether the
      article was truncated, and never the article, the prompt or the summary.
    * **The OpenTelemetry login token is in the Pod's log.** Aspire prints its login link, token included, when it
      starts, so whoever may read the logs of Pods in the `observability` namespace can sign in to the dashboard.
    * **The inventory is sensitive, and it includes the environment.** The jars of an application with their versions
      and checksums show which known vulnerabilities it has. The report to jlib-server also carries the JVM's command
      line and flags, **every environment variable** and every system property, and the jlib-inspector dashboard shows
      them on the application's JVM page to anyone who can reach it. The agent has no option to leave any of them out.
      A secret must reach an application on the `java-25-jlib` runtime as a mounted file, never as an environment
      variable, a `-D` property or an argument. The summarizer reads its connection token that way (see
      [the credential boundary](#the-credential-boundary)), and `make check` fails an app on that runtime that has a
      credential-named or Secret-backed environment variable.
    * **The jlib-inspector dashboard's page loads two scripts from the internet** (Tailwind CSS and the Lucide icons,
      the latter at `@latest`). They run in your browser, on the page that can repoint the dashboard.
    * **The Brewlet dashboard's token reads every namespace.** The role `brewlet-dashboard-viewer` reads Pods, events,
      nodes and workload controllers cluster-wide, and Pod specs carry every environment value that is not a Secret
      reference, for every application. The token `make dashboards` prints is valid for one hour and cannot write.

## Before you adapt this for a real cluster

1. Put the registry behind TLS and authentication, and keep Brewlet's digest pinning.
2. Encrypt Secrets at rest or fetch them from an external store, and use a dedicated Copilot
   identity per environment.
3. Add a NetworkPolicy that allows the sidecar to reach GitHub and nothing else, and allows ingress
   to the agent only from its callers.
4. Set the CPU and memory requests from measurements ([agents overview](agents/index.md) has some).
5. Decide who may approve a `RuntimeImage`; in Brewlet that is the point at which Ops takes
   responsibility for a runtime.
6. Put the observability stack behind the same controls as the rest: NetworkPolicies so that only the Pods that
   report reach jlib-server and the OTLP ports, an authenticating proxy (or OpenID Connect, for the Aspire
   dashboard) in front of the dashboards, an API key or client certificate on OTLP, and the jlib-inspector
   dashboard's two scripts served from your own origin. Bind the Brewlet dashboard's viewer role to the people
   who may see every namespace, not to a shared ServiceAccount.
