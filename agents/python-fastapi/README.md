# python-fastapi

FastAPI on Python 3.13: the Runtime Concierge built with the `copilot-fastapi` integration, shipped as a Brewlet
artifact with the code and its `site-packages` but no interpreter and no Copilot CLI. The contract is in
[`agents/README.md`](../README.md).

## What is in the artifact

```text
/app/site-packages/  layer "deps"   24 distributions: FastAPI, uvicorn, pydantic, the Copilot SDK and integration
/app/concierge/      layer "code"   the agent's package: app, agent, settings, facts, probe, prompts/concierge.md
launch.json          launch layer   /usr/bin/python3 -m concierge, PYTHONPATH=/app/site-packages:/app
```

Compressed: **9.5 MiB** in all (`deps` 9.5 MiB, `code` 16.4 KiB, `launch.json` 319 B; see `make layers
AGENT=python-fastapi`), 32 MiB unpacked, linux/arm64.

Deliberately **not** in it: CPython and its standard library (`/usr` comes from the `python-3.13` runtime image, which
has no pip and no shell) and the Copilot CLI (it runs in the sidecar). The files over 2 MiB are
`copilot/_generated/rpc.py` (4.5 MiB, plus 5.0 MiB of bytecode) and pydantic's native module (4.7 MiB).

Measured on the kind cluster; [`deployment.yaml`](deployment.yaml) asks for 100m CPU, 128Mi, limit 256Mi:

| working set | fresh Pod | after one ask | 12 asks at once |
| --- | --- | --- | --- |
| agent | 92 MiB | 94 MiB | 95 MiB |
| Copilot CLI sidecar (limit 512Mi) | 16 MiB | 58 MiB | 147 MiB |

The Pod is Ready about 3 s after it is scheduled (the startup probe polls every 2 s); the server itself answers
`/readyz` 1.3 s after its container starts. `make build` takes about 9 s.

## How the integration is used

The agent is a class and its one tool a function. The system prompt is package data, the same file in every agent;
`/runtime` and the tool read the same facts object, so what the model says and what the endpoint shows cannot drift:

```python
@copilot_tool(description="Verified facts about the environment this agent runs in: ...")
async def runtime_facts(ctx: ToolContext, topic: Annotated[str | None, Field(description="...")] = None) -> str:
    return await ctx.agent.attributes["facts"].text(topic)

class ConciergeAgent(CopilotAgent):
    instructions = files("concierge").joinpath("prompts/concierge.md").read_text(encoding="utf-8")
    tools = [runtime_facts]
    available_tools = ["custom:runtime_facts"]       # only the agent's own tool, see Gotchas
    permissions = policies.allow_registered_tools()
    working_directory = no_working_directory         # the sidecar has its own filesystem
```

[`app.py`](src/concierge/app.py) wires it in: the integration's `lifespan` owns the connection to the sidecar, and
`copilot.depends` builds one agent per request with the facts object attached:

```python
copilot = Copilot(settings.copilot(), agents=[ConciergeAgent])
Concierge = Annotated[ConciergeAgent, copilot.depends(ConciergeAgent, facts=Depends(get_facts))]
app = FastAPI(lifespan=copilot.lifespan, docs_url=None, redoc_url=None, openapi_url=None)
# POST /ask: answer = await agent.aask(question, conversation_id=conversation_id, timeout=settings.response_timeout)
```

[`settings.py`](src/concierge/settings.py) reads the environment: `COPILOT_CLI_URL` and `COPILOT_CONNECTION_TOKEN` have
no defaults (a Pod without them fails at startup), `PORT` is 8080 on `0.0.0.0`, `RESPONSE_TIMEOUT` 120 s (then
`504 timeout`), `PROBE_TIMEOUT` 3 s, `SHUTDOWN_TIMEOUT` 15 s (the grace SIGTERM gives requests in flight) and
`SESSION_MAX_AGE` 1 h. `Settings.copilot()` maps them onto the integration's `CopilotSettings` (`connection: "uri"`).
`python -m concierge` starts uvicorn with one worker.

## Build notes

* Host tool: `uv`, which also downloads the CPython 3.13 that runs the build (the host's own Python is not used).
* [`build.sh`](build.sh) resolves for the Linux target, not the host: `uv pip install --python-version 3.13
  --python-platform <aarch64|x86_64>-manylinux_2_28 --only-binary :all: --target site-packages -r requirements.txt
  <wheels>`. The runtime has no compiler and no pip, so only binary wheels qualify. `pydantic_core` is the one compiled
  dependency: an `ARCH=amd64` build differs only in that file (5.1 MiB, not 4.7) and runs in the runtime image as amd64.
* The integrations are not on PyPI. `scripts/integrations/languages/python.sh` (run by `make build`) builds wheels of
  `copilot-agent-core` and `copilot-fastapi` from the pinned `copilot-sdk-integrations` commit into
  `build/integrations/python/`; [`requirements.txt`](requirements.txt) pins everything else exactly.
* Two layers ([`layers`](layers)): the libraries, then the package, so a code change ships 16 KiB instead of 9.5 MiB.
  Rebuilding unchanged sources gives the same artifact digest (checked twice).
* Bytecode is shipped, because the read-only root filesystem keeps Python from caching it at run time. `compileall
  --invalidation-mode unchecked-hash` (the pipeline pins every mtime, so timestamped `.pyc` files would be stale) adds
  4.6 MiB to the compressed `deps` layer and saves 0.8 s: `/readyz` is up 1.3 s after the container starts, not 2.1 s.
* Removed after the install: `direct_url.json` (it names this host's wheel paths), `INSTALLER`, `REQUESTED`, `bin/`
  (console scripts whose shebangs name this host's Python) and `copilot/bin`, should a platform wheel of the SDK
  bundle the Copilot CLI there (the pinned universal wheel does not, so the guard saves nothing today).

## Run it

```bash
make agent AGENT=python-fastapi      # build, publish, deploy, smoke test (make auth for the /ask checks)
make ask AGENT=python-fastapi Q="Which language runtime are you on and where is it installed?"
# I'm running on CPython 3.13.5. Its home directory is `/usr`.
kubectl -n agents port-forward deploy/python-fastapi 18301:8080 &      # or call it directly:
curl -s localhost:18301/ask -H 'content-type: application/json' -d '{"question":"Which web framework are you on?"}'
# {"answer":"I'm on **FastAPI**, version 0.165.0. The application code is ...","conversationId":"3b397d5f-..."}
```

## Gotchas

* **`built_in_tools=False` is not enough.** It only adds `builtin:*` to the deny-list: the shell and file tools
  disappear, but the Copilot CLI's own GitHub MCP tools (`github-mcp-server-*`, which can read repositories with the
  sidecar's token) and `web_search` stay listed and callable. `available_tools = ["custom:runtime_facts"]` is an
  allow-list over every tool source, and the model then lists only `runtime_facts`. The integration rejects combining
  it with `built_in_tools=False` or `excluded_tools`, and requires it to name the agent's own tool (`custom:*` works
  too). `make smoke` asks the model to list its tools and fails if a GitHub, web or shell tool shows up.
* **Empty session mode.** Sessions start with `mode: "empty"` (no default prompt or tools), so each must name its
  tools: `available_tools`. The integration also sends this process's working directory, which the sidecar's filesystem
  lacks (`working_directory` returns nothing), and creates its state directory even when it only attaches (`/tmp`).
* **The Pod's variable names are not the integration's.** `CopilotSettings` reads `COPILOT_RUNTIME__URL`,
  `COPILOT_RUNTIME__CONNECTION_TOKEN` and so on; the Pod provides `COPILOT_CLI_URL` and `COPILOT_CONNECTION_TOKEN`.
  The agent's own `Settings` reads the Pod's names and builds `CopilotSettings` from them explicitly.
* **Error bodies.** FastAPI and the integration answer with `{"detail": ...}` (422 for a bad body); the contract wants
  `{"error", "message"}`, so a `RequestValidationError` handler and the route produce it: `400 bad_request`, `503
  copilot_not_authenticated` / `copilot_unavailable`, `504 timeout` (`CopilotTimeout`), `502 agent_error` otherwise.
* **The integration never reconnects.** The core runtime caches its SDK client for good and the SDK only starts a
  client that has none, so after a sidecar restart the dead connection is reused: `/readyz` stays 503 while `/healthz`
  stays 200, and the kubelet never restarts the agent. `SidecarProbe` calls `client.start()` before each probe (a
  no-op while connected), so `/readyz` is back 1-2 s after a restart. The core should reset its client when it drops.
* **Conversation ids.** The sidecar only accepts session ids of `[A-Za-z0-9_-]`; the integration hashes the
  conversation id into one, so every character the contract allows (`.`, `:`, `/`) works and `/ask` echoes the id.
