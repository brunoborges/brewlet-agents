# node-nestjs

NestJS on Node 24: the Runtime Concierge built with `@copilot-sdk-integrations/nestjs`. It ships as a
Brewlet artifact that holds the code and its `node_modules`, with no Node.js and no Copilot CLI inside.
The contract is in `agents/README.md`.

## What is in the artifact

```text
/app/package.json          deps layer   the manifest the dependencies were installed from
/app/node_modules/         deps layer   production dependencies only, pure JavaScript, 37 MB
/app/dist/                 code layer   the compiled TypeScript (CommonJS), 44 KB
/app/prompts/concierge.md  code layer   the system prompt, read at startup relative to dist/
launch.json                             /nodejs/bin/node /app/dist/main.js, workingDir /app, NODE_ENV=production
```

Compressed: **4.7 MiB** in all (`deps` 4.7 MiB, `code` 7.4 KiB, `launch.json` 262 B; `make layers AGENT=node-nestjs`).
A code-only change pushes about 8 KiB.

Deliberately not in it: Node.js (the `node-24` runtime supplies `/nodejs/bin/node`), the Copilot CLI
(it runs in the sidecar), TypeScript and every other dev dependency, and the SDK's bundled Copilot
runtime (`@microsoft/copilot-sdk-linux-arm64`, 89 MB compressed, 197 MB on disk; see Gotchas).

## How the integration is used

The agent is an abstract class; the module implements it by sending each question to the sidecar:

```ts
@CopilotAgent({
  name: "concierge",
  instructions,                                   // prompts/concierge.md
  tools: [RuntimeFacts],
  availableTools: ["custom:runtime_facts"],       // the model sees this tool and nothing else
  permissions: permissions.allowCustomTools(["runtime_facts"]),
})
export abstract class ConciergeAgent {
  @UserMessage()
  ask(@ConversationId() conversationId: string, @Message() question: string): Promise<string> {
    return implementedByCopilot();
  }
}
```

`RuntimeFacts` is an injectable whose method is the tool and which also builds `GET /runtime`, so both read the same facts:

```ts
@CopilotTool({ name: "runtime_facts", description: "...", input: TopicInput })   // zod schema
async runtimeFacts({ topic }: z.infer<typeof TopicInput>): Promise<string> { /* flat "key: value" lines */ }
```

`CopilotModule.forRootAsync` takes its options from `AppConfig`, which reads the environment:

```ts
{ cliUrl: config.cliUrl, startup: "lazy", responseTimeout: config.responseTimeoutMs,
  sessionCleanup: { maxAge: config.sessionMaxAgeMs }, shutdownGracePeriod: config.shutdownGraceMs,
  configureClient: /* adds the connection token */, exceptionFilter: false }
```

| Variable | Default | Meaning |
|---|---|---|
| `COPILOT_CLI_URL`, `COPILOT_CONNECTION_TOKEN` | none: startup fails without them | the sidecar (`127.0.0.1:4321`) and its token |
| `PORT` | `8080` | listen port (on `0.0.0.0`) |
| `COPILOT_RESPONSE_TIMEOUT_MS` | `120000` | a slower answer is `504 timeout` |
| `COPILOT_SESSION_MAX_AGE_MS` | `3600000` | idle conversations are deleted after this |
| `COPILOT_PROBE_TIMEOUT_MS` | `3000` | how long `/readyz` and `/runtime` wait for the sidecar |
| `SHUTDOWN_GRACE_MS` | `10000` | how long SIGTERM waits for in-flight questions |
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
make agent AGENT=node-nestjs     # build, publish, deploy, smoke
make ask AGENT=node-nestjs Q="Which language runtime are you on and where is it installed?"
# I'm on Node.js 24.22.3, and its home directory is `/nodejs`.
```

The container listens about 0.3 s after it starts; the Pod is Ready about 6 s after it is scheduled (the Copilot
client connects on the first readiness probe). Measured on the kind node (`crictl stats`, working set): the agent
holds 52-76 MB idle and 65-84 MB after bursts, and peaked at 80-102 MB with 16 concurrent questions and 83 MB with
32; the sidecar holds 17 MB before its first question, 33-72 MB after some, and peaked at 166-170 MB (16 concurrent)
and 220 MB (32). Hence `100m` and `96Mi` requests and a `192Mi` limit (about twice the agent's worst peak).

## Gotchas

* **Lock the tool list with an allow-list, not a deny-list.** Excluding the CLI's built-in tools still leaves its
  own GitHub MCP tools (`github-mcp-server-*`, which can read repositories with the sidecar's token) and
  `web_search` callable. `availableTools: ["custom:runtime_facts"]` in `@CopilotAgent` allow-lists every tool
  source down to the agent's own tool (unset, the integration's default is `["custom:*", "mcp:*"]`). Asking the
  model to list its tools (the last smoke check, or `make ask`) prints only `runtime_facts`.
* **The integration has no connection-token option** (`cliUrl` carries no token). `configureClient`
  rebuilds the TCP connection it derived from `cliUrl` with `RuntimeConnection.forTcp(host, port, { connectionToken })`.
* **Error bodies.** The integration's default exception filter answers `{statusCode, error, message}`, not the
  contract's `{error, message}`: it is turned off and `ConciergeController` maps `CopilotTimeoutError` to `504`,
  `CopilotRuntimeUnavailableError` to `503` and anything else to `502`. A malformed JSON body gets Nest's own `400`.
* **The SDK's bundled runtime stays out.** `@microsoft/copilot-sdk` lists per-platform packages as optional
  dependencies (the CLI runtime for in-process use); `--omit=optional` drops them and the agent never needs them.
  `koffi`, a hard dependency that only that in-process mode loads, stays as 1.9 MB of JavaScript; skipping
  its install script (`--ignore-scripts`) means its native addon is never fetched or built.
* **CommonJS meets ESM.** The Nest app compiles to CommonJS and `require`s the ESM-only integration packages
  (`require(esm)`, Node 22.12 or newer; the runtime is 24).
* `@nestjs/event-emitter`, `@nestjs/terminus` and `nestjs-cls` are optional peers of the integration, not installed.
* The integration's `ClientLike` does not type `ping`, `getStatus` or `getAuthStatus`, so `SidecarProbe`
  casts the client from `copilot.client()` to the SDK's `CopilotClient`.
* `@microsoft/copilot-sdk/package.json` is not an exported path, so `packageInfo()` finds each package's
  directory by name to report the SDK and integration versions and locations.
* There is no instructions-from-file option, so `concierge.agent.ts` reads `prompts/concierge.md` next to `dist/`.
