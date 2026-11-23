# node-fastify

Fastify 5 on Node 24: the Runtime Concierge built with `@copilot-sdk-integrations/fastify`. It ships as a
Brewlet artifact that holds the code and its `node_modules`, with no Node.js and no Copilot CLI inside.
The contract is in `agents/README.md`.

## What is in the artifact

```text
/app/package.json          deps layer   the manifest the dependencies were installed from, with "type": "module"
/app/node_modules/         deps layer   production dependencies only, pure JavaScript, 30 MB
/app/dist/                 code layer   the compiled TypeScript (ES modules), 40 KB
/app/prompts/concierge.md  code layer   the system prompt, read at startup relative to dist/
launch.json                             /nodejs/bin/node /app/dist/main.js, workingDir /app, NODE_ENV=production
```

Compressed: **4.2 MiB** in all (`deps` 4.2 MiB, `code` 7.2 KiB, `launch.json` 262 B; `make layers AGENT=node-fastify`);
a code-only change pushes about 7 KiB.

Deliberately not in it: Node.js (the `node-24` runtime supplies `/nodejs/bin/node`), the Copilot CLI
(it runs in the sidecar), TypeScript and every other dev dependency, and the SDK's bundled Copilot
runtime (`@microsoft/copilot-sdk-linux-arm64`, 89 MB compressed, 197 MB on disk; see Gotchas).

## How the integration is used

The agent is a definition that `buildApp` registers on the plugin's `app.copilot`; the route sends each
question to it. The request-scoped `request.copilot` also ends the turn if the client disconnects:

```ts
defineAgent({
  name: "concierge",
  instructions,                                   // prompts/concierge.md
  tools: [facts.tool()],
  availableTools: ["custom:runtime_facts"],       // the model sees this tool and nothing else
  permissions: permissions.allowCustomTools(["runtime_facts"]),
})

const answer = await request.copilot.agent("concierge").send({ prompt: question, conversationId });
```

The tool is a method of `RuntimeFacts`, which also builds `GET /runtime`, so both read the same facts:
`defineCopilotTool({ name: "runtime_facts", input: TopicInput /* zod */, execute })` returns flat `key: value` lines.

The plugin takes its options from `AppConfig`, which reads the environment:

```ts
await app.register(copilotPlugin, {
  client: { cliUrl: config.cliUrl, responseTimeout: config.responseTimeoutMs, configureClient: /* adds the token */ },
  startup: "lazy", sessionCleanup: { maxAge: config.sessionMaxAgeMs },
  shutdownGracePeriod: config.shutdownGraceMs, errorHandler: false,
});
```

| Variable | Default | Meaning |
|---|---|---|
| `COPILOT_CLI_URL`, `COPILOT_CONNECTION_TOKEN` | none: startup fails without them | the sidecar (`127.0.0.1:4321`) and its token |
| `PORT` | `8080` | listen port (on `0.0.0.0`) |
| `COPILOT_RESPONSE_TIMEOUT_MS` | `120000` | a slower answer is `504 timeout` |
| `COPILOT_SESSION_MAX_AGE_MS` | `3600000` | idle conversations are deleted after this |
| `COPILOT_PROBE_TIMEOUT_MS` | `3000` | how long `/readyz` and `/runtime` wait for the sidecar |
| `SHUTDOWN_GRACE_MS` | `10000` | how long SIGTERM waits for in-flight questions |
| `LOG_LEVEL` | `info` | pino level; the JSON logs skip the probes' requests |
| `AGENT_NAME`, `AGENT_RUNTIME_ID`, `POD_NAME`, `POD_NAMESPACE`, `NODE_NAME` | | reported by `/runtime` |

## Build notes

`build.sh` runs `npm install --os=linux --cpu=<arm64|x64> --libc=glibc --omit=optional --ignore-scripts`,
compiles with `tsc`, runs `npm prune --omit=dev`, then moves `node_modules` to the `deps` layer and
`dist/` plus `prompts/` to the `code` layer. Nothing is compiled natively, so the result does not depend
on the host's Node (26) or the runtime's (24); the script fails if a `*.node` file appears. It also deletes
npm's hidden `node_modules/.package-lock.json`, which would leak the registry's URLs and host paths.

The integration packages are not published. `scripts/integrations/languages/node.sh` (run by `make build`) packs them
from the pinned `copilot-sdk-integrations` commit into `build/integrations/node/*.tgz`, and `package.json`
points at them with repository-relative `file:../../build/integrations/node/...`. Direct dependencies are
pinned exactly and the transitive ones resolve at build time. No `package-lock.json` is committed: a lockfile
would record this registry mirror's URLs and `build/` outputs. Two from-scratch builds gave the same digest.

## Run it

```bash
make agent AGENT=node-fastify     # build, publish, deploy, smoke
make ask AGENT=node-fastify Q="Which language runtime are you on and where is it installed?"
# I'm running on Node.js 24.22.3, and its home directory is `/nodejs`.
```

The container listens 0.15-0.3 s after it starts; the Pod is Ready about 4 s after it is scheduled. Measured on
the kind node (`crictl stats`, working set): the agent holds 38 MB on a fresh Pod and 44-92 MB after a few
questions (the working set counts file cache the kernel can reclaim; the RSS stays near 35 MB), and peaked at 74 MB with
16 concurrent questions and 93 MB with 32. The sidecar holds 17 MB idle, 27-136 MB after a few questions and
peaked at 183 MB (16 at once) and 291 MB (32 at once). Hence `100m` and `96Mi` requests and a `192Mi` limit.

## Gotchas

* **Lock the tool list with an allow-list, not a deny-list.** Excluding the CLI's built-in tools still leaves its
  own GitHub MCP tools (`github-mcp-server-*`, which can read repositories with the sidecar's token) and
  `web_search` callable. `availableTools: ["custom:runtime_facts"]` in `defineAgent` allow-lists every tool
  source down to the agent's own tool (unset, the integration's default is `["custom:*", "mcp:*"]`). Asking the
  model to list its tools (the last smoke check, or `make ask`) prints only `runtime_facts`.
* **The integration has no connection-token option** (`cliUrl` carries no token). `configureClient`
  rebuilds the TCP connection it derived from `cliUrl` with `RuntimeConnection.forTcp(host, port, { connectionToken })`.
* **Error bodies.** The plugin's default handler answers `{statusCode, code, error, message}` with statuses the
  contract lacks (`429`, `409`, `404`). It is turned off (`errorHandler: false`); `src/problem.ts` is the root
  handler: `CopilotTimeoutError` is `504 timeout`, an unreachable or shutting-down runtime `503 copilot_unavailable`,
  anything else the agent throws `502 agent_error`, and Fastify's own client errors (malformed JSON, `413`, `415`)
  keep their status with `bad_request`. A client that disconnects mid-question is logged as `499` and gets nothing.
* **Register the agent after the plugin.** `RuntimeFacts` and `SidecarProbe` read the client the plugin manages
  (`app.copilot`), so `buildApp` registers the plugin first and then calls `app.copilot.registerAgent(...)`.
* **The SDK's bundled runtime stays out.** `@microsoft/copilot-sdk` lists per-platform packages as optional
  dependencies (the CLI runtime for in-process use); `--omit=optional` drops them and the agent never needs them.
  `koffi`, a hard dependency that only that in-process mode loads, stays as 1.9 MB of JavaScript; skipping
  its install script (`--ignore-scripts`) means its native addon is never fetched or built.
* `ai` and `@copilot-sdk-integrations/ai` are optional peers of the plugin (Vercel AI SDK routes), not installed.
* The integration's `ClientLike` does not type `ping`, `getStatus` or `getAuthStatus`, so `SidecarProbe` casts
  the client from `copilot.client()` to the SDK's `CopilotClient`. `@microsoft/copilot-sdk/package.json` is not an
  exported path, so `packageInfo()` resolves the entry point with `import.meta.resolve` and walks up to the manifest.
* There is no instructions-from-file option, so `concierge.ts` reads `prompts/concierge.md` next to `dist/`.
* The probe paths are silenced with a `LogController` (the top-level `disableRequestLogging` is deprecated in 5.12).
  Bound to `0.0.0.0`, Fastify logs one `Server listening at` line per interface (two in the Pod); `main.ts` adds
  a summary line with the startup time.
