# Agents

Eight small agents, one per framework, that all do the same thing: **the Runtime Concierge**. It
is a deliberately tiny agent whose only job is to tell you, truthfully, what it is running on. That
makes the Brewlet story observable: ask it which language runtime, SDK and Copilot CLI it uses, and
the answer comes from the live process, not from the documentation.

| Agent | Language | Framework | Runtime id |
|-------|----------|-----------|------------|
| `java-spring` | Java 25 | Spring Boot | `java-25` |
| `java-quarkus` | Java 25 | Quarkus | `java-25` |
| `java-micronaut` | Java 25 | Micronaut | `java-25` |
| `node-nestjs` | Node.js 24 | NestJS | `node-24` |
| `node-fastify` | Node.js 24 | Fastify | `node-24` |
| `python-fastapi` | Python 3.13 | FastAPI | `python-3.13` |
| `python-django` | Python 3.13 | Django | `python-3.13` |
| `dotnet-aspnet` | .NET 10 | ASP.NET Core | `dotnet-10` |

## The deployment model

```text
                        ┌────────────────────────── one Pod ───────────────────────────┐
                        │                                                              │
  Ops team owns   ───►  │  agent container                  copilot-cli container      │
                        │  ┌──────────────────────┐         ┌──────────────────────┐   │
  Brewlet runtime  ───► │  │ /usr/jdk (Java 25)   │         │ Copilot CLI          │   │
  (framework-agnostic)  │  │ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─│         │ headless, TCP :4321  │   │
                        │  │ /app  (read-only)    │ ──────► │ holds the GitHub     │   │
  Dev team owns   ───►  │  │   code + libraries   │ loopback│ credentials          │   │
  OCI artifact          │  │   + launch.json      │         └──────────────────────┘   │
                        │  └──────────────────────┘                                    │
                        └──────────────────────────────────────────────────────────────┘
```

* The **application artifact** is an OCI image with the code, **all** of its dependencies (including
  the Copilot SDK and its framework integration) and a Brewlet `launch.json`. Nothing else.
* The **runtime** is a plain, framework-agnostic language image (`java-25`, `node-24`,
  `python-3.13`, `dotnet-10`) approved, patched and rotated by Ops. No runtime contains a framework
  or the Copilot SDK, so the same runtime serves every framework of that language.
* The **Copilot CLI** is a separate sidecar container (`sidecars/copilot-cli`). The SDK reaches it
  over the Pod's loopback interface, authenticating with a shared connection token. It is the only
  container that ever holds GitHub credentials.

## The Runtime Concierge contract

Every agent serves HTTP on `$PORT` (8080) and is validated by `scripts/agent-smoke.sh`, which is the
executable form of this contract.

### Endpoints

| Request | Response |
|---------|----------|
| `GET /healthz` | `200 {"status":"UP"}`. Liveness. Never depends on the sidecar. |
| `GET /readyz` | `200 {"status":"READY"}` once the Copilot CLI sidecar answers a ping (3 s timeout), otherwise `503 {"status":"NOT_READY","reason":"copilot_cli_unreachable"}`. |
| `GET /runtime` | `200` with the document below. Works without credentials and while the sidecar is down. |
| `POST /ask` | Asks the agent a question. See below. |

`GET /runtime`, read from the live process:

```json
{
  "agent":      { "name": "java-spring",
                  "framework": { "name": "Spring Boot", "version": "4.1.1" },
                  "location": "/app/app.jar" },
  "language":   { "name": "java", "version": "25.0.5.1+2-LTS", "vendor": "Microsoft", "home": "/usr/jdk" },
  "copilot": {
    "sdk":         { "name": "com.microsoft:copilot-sdk", "version": "2.0.1", "location": "/app/lib/copilot-sdk-2.0.1.jar" },
    "integration": { "name": "com.microsoft:copilot-spring-boot-autoconfigure", "version": "0.1.0-SNAPSHOT", "location": "/app/lib/copilot-spring-boot-autoconfigure-0.1.0-SNAPSHOT.jar" },
    "cli":         { "endpoint": "127.0.0.1:4321", "attached": true, "version": "1.0.114",
                     "protocolVersion": 4, "authenticated": true, "authType": "token" }
  },
  "deployment": { "runtimeId": "java-25", "pod": "java-spring-598d46bdc-8jxjj", "namespace": "agents", "node": "brewlet-agents-control-plane" }
}
```

* `agent.location` is under `/app` (the artifact); `language.home` is **not** (the runtime). This
  is the point of the demo, and the smoke test asserts it.
* When the sidecar is unreachable `copilot.cli` is `{"endpoint": "...", "attached": false, "error": "..."}`.
* It never contains the GitHub login, a token or the connection token.

`POST /ask` takes `{"question": "...", "conversationId": "..."}`. `question` is required (at most
4000 characters). `conversationId` is optional (`[A-Za-z0-9._:/-]{1,128}`); the agent generates a UUID
when it is omitted, and reuses the same Copilot session for the same id. The response always carries
the caller's own id back.

> [!NOTE]
> The conversation id is not the Copilot session id. The sidecar only accepts session ids made of
> `[A-Za-z0-9_-]`, narrower than the contract. An agent therefore maps the conversation id to a session
> id by hashing it (the Java, Node.js and Python integrations do this themselves; the .NET agent does it
> in its own code). The smoke test sends an id that uses every allowed character, so a framework that
> passes the id through unchanged fails it.

| Status | Body | When |
|--------|------|------|
| 200 | `{"answer":"...","conversationId":"..."}` | The model answered. |
| 400 | `{"error":"bad_request","message":"..."}` | Missing, blank or oversized `question`, or a malformed `conversationId`. |
| 503 | `{"error":"copilot_not_authenticated","message":"..."}` | The sidecar is up but has no GitHub credentials (`make auth`). |
| 503 | `{"error":"copilot_unavailable","message":"..."}` | The sidecar cannot be reached. |
| 504 | `{"error":"timeout","message":"..."}` | No answer within 2 minutes. |
| 502 | `{"error":"agent_error","message":"..."}` | Any other failure reported by the SDK. |

### Behavior

* **System prompt** is a file resource, `prompts/concierge.md`, **identical in every agent**, loaded
  the way the framework idiomatically loads resources (a classpath resource, a file read relative to
  the module, package data, an embedded resource, and so on). Never inline it in code.
* **One tool**, `runtime_facts(topic)` with `topic` one of `all`, `agent`, `language`, `copilot`,
  `deployment`. It returns the matching part of the `/runtime` document as flat `key: value` lines
  (`language.home: /usr/jdk`). The prompt makes the model call it before answering anything about
  versions, paths or the deployment.
* **The model can call `runtime_facts` and nothing else.** The session allow-lists only the agent's
  own tool (`custom:*`), and permissions allow only that tool. Excluding the CLI's built-in tools is
  *not* enough: the Copilot CLI's own GitHub MCP tools (which could read repositories with the
  sidecar's token) and `web_search` stay callable. The smoke test asks the model to list the tools it
  can call and fails on anything but `runtime_facts`.
* **No model is hard-coded.** Sessions use the account's default model.
* **Configuration is external.** Endpoint, token, timeouts and tool settings come from the
  framework's configuration mechanism (`application.yml`, `config/*.json`, settings module, ...) with
  environment overrides, not constants in code.

### Environment

The Pod sets these; the agent reads them and has no defaults for the first two.

| Variable | Meaning |
|----------|---------|
| `COPILOT_CLI_URL` | `127.0.0.1:4321`, where the sidecar listens. |
| `COPILOT_CONNECTION_TOKEN` | Shared secret the SDK must present to the sidecar (from a Kubernetes Secret). |
| `PORT` | HTTP port, `8080`. |
| `AGENT_NAME`, `AGENT_RUNTIME_ID` | The agent's name and the Brewlet runtime id it runs on. |
| `POD_NAME`, `POD_NAMESPACE`, `NODE_NAME` | Downward API; reported in `/runtime`. |

## What an agent directory contains

```text
agents/<name>/
├── agent.env      AGENT_NAME, LANGUAGE (java|node|python|dotnet), FRAMEWORK, RUNTIME, PORT,
│                  optional CPU_REQUEST, MEMORY_REQUEST, MEMORY_LIMIT
├── launch.json    Brewlet launch descriptor; runtimeImages lists RUNTIME
├── layers         optional: one "<directory under $APP_DIR>:<path in the artifact>" per line
├── build.sh       fills $APP_DIR with the final linux/$ARCH file system
├── README.md      what the example shows and the framework specifics
└── <sources>
```

* `agent.env` is **parsed, never sourced**: plain `KEY=VALUE`, no quotes, no shell syntax.
* `build.sh` runs with `APP_DIR` (output directory), `ARCH` (`arm64` or `amd64`) and
  `INTEGRATIONS_OUT` (the pinned integrations for this language, built by
  `scripts/integrations-build.sh`). Dependencies must be resolved for **linux/`$ARCH` and the
  runtime's ABI**, not for the build host; Brewlet runs no package manager.
* `layers` stacks layers in order. Put the stable, large layer (dependencies) first and the small,
  fast-changing one (your code) last, so a code change re-pushes kilobytes, not megabytes.
* The artifact file system must be world-readable and free of extended attributes;
  `scripts/agent-build.sh` normalizes modes and strips macOS attributes before packaging.
* `launch.json` is the only contract with the runtime: an absolute `entrypoint` (the runtime's
  interpreter), `args`, `workingDir: "/app"`, an `env` without `PATH`, and `runtimeImages`.

The runtime catalog is in `runtimes/*.env` (interpreter path, uid and the writable mount paths the
runtime allows, which is `/tmp`).

## Build, deploy, verify

```bash
make up                         # once: cluster, Brewlet, runtimes, Copilot CLI sidecar
make agent AGENT=java-spring    # build, publish, deploy, smoke-test
make auth                       # optional: let the sidecar call the model with your GitHub login
make smoke AGENT=java-spring    # now includes a live round trip through the model
```
