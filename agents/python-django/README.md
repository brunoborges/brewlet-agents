# python-django

Django on Python 3.13: the Runtime Concierge built with the `copilot-django` integration, an API-only ASGI project
served by uvicorn and shipped as a Brewlet artifact with its `site-packages` but no interpreter and no Copilot CLI.
The contract is in [`agents/README.md`](../README.md).

## What is in the artifact

```text
/app/site-packages/  layer "deps"   21 distributions: Django, uvicorn, pydantic, the Copilot SDK and integration
/app/concierge/      layer "code"   the Django project: settings, urls, views, agent, tool, facts, prompt
launch.json          launch layer   /usr/bin/python3 -m concierge, PYTHONPATH=/app/site-packages:/app
```

Compressed: **13.5 MiB** in all (`deps` 13.4 MiB, `code` 20.3 KiB, `launch.json` 319 B; see `make layers
AGENT=python-django`), 44 MiB unpacked, linux/arm64.

Deliberately **not** in it: CPython and its standard library (`/usr` comes from the `python-3.13` runtime image, which
has no pip and no shell), the Copilot CLI (it runs in the sidecar) and Django's translation catalogs (see Build notes).
The files over 2 MiB are `copilot/_generated/rpc.py` (4.5 MiB, plus 5.0 MiB of bytecode) and pydantic's native module.

Measured on the kind cluster; [`deployment.yaml`](deployment.yaml) asks for 100m CPU, 128Mi, limit 256Mi:

| working set | fresh Pod | after one ask | 12 asks at once |
| --- | --- | --- | --- |
| agent | 96-103 MiB | 96 MiB | 98 MiB |
| Copilot CLI sidecar (limit 512Mi) | 16-19 MiB | 107 MiB | 187 MiB |

The Pod is Ready about 4 s after it is scheduled (the startup probe polls every 2 s); the server itself answers
`/readyz` 1.3 s after its container starts. `make build` takes about 27 s: the tree has 3,780 files, twice FastAPI's.

## How the integration is used

The agent is a class and its one tool a function; `copilot_django` imports the `copilot_tools` and `copilot_agents`
modules of every installed app at startup, which registers them. The system prompt is package data:

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

[`settings.py`](src/concierge/settings.py) is API-only Django plus the integration's `COPILOT` dict (an attach to the
sidecar over TCP with the Pod's `COPILOT_CLI_URL` and `COPILOT_CONNECTION_TOKEN`); [`views.py`](src/concierge/views.py)
builds `ConciergeAgent(user=None, request=None)` for each `/ask` and awaits `agent.aask(question, conversation_id=...)`:

```python
COPILOT = {"RUNTIME": {"CONNECTION": "uri", "URL": COPILOT_CLI_URL, "CONNECTION_TOKEN": COPILOT_CONNECTION_TOKEN,
                       "MODE": "empty", "BASE_DIRECTORY": STATE_DIR}, "SESSIONS": {"MAX_AGE": SESSION_MAX_AGE}}
```

The two Pod variables have no defaults (without them the project fails at startup with `ImproperlyConfigured`). `PORT`
is 8080 on `0.0.0.0`, `RESPONSE_TIMEOUT` 120 s (then `504 timeout`), `PROBE_TIMEOUT` 3 s, `SHUTDOWN_TIMEOUT` 15 s (the
grace SIGTERM gives requests in flight) and `SESSION_MAX_AGE` 1 h. `python -m concierge` starts uvicorn with one worker
and `lifespan="off"` (Django's ASGI handler does not speak lifespan). `/runtime` and the tool share one facts object.

## Build notes

* [`build.sh`](build.sh) needs only `uv` on the host (it also downloads the CPython 3.13 that runs the build) and
  resolves for the Linux target, not the host: `uv pip install --python-version 3.13 --python-platform
  <aarch64|x86_64>-manylinux_2_28 --only-binary :all: --target site-packages -r requirements.txt <wheels>`. The runtime
  has no compiler and no pip, so only binary wheels qualify. `pydantic_core` is the one compiled dependency: an
  `ARCH=amd64` build differs only in that file (5.1 MiB, not 4.7) and runs in the runtime image as amd64.
* The integrations are not on PyPI. `scripts/integrations/languages/python.sh` (run by `make build`) builds wheels of
  `copilot-agent-core` and `copilot-django` from the pinned `copilot-sdk-integrations` commit into
  `build/integrations/python/`; [`requirements.txt`](requirements.txt) pins everything else exactly.
* Two layers ([`layers`](layers)): the libraries, then the project, so a code change ships 20 KiB instead of 13.4 MiB;
  rebuilding unchanged sources gives the same artifact digest.
* Bytecode is shipped, because the read-only root filesystem keeps Python from caching it at run time. `compileall
  --invalidation-mode unchecked-hash` (the pipeline pins every mtime, so timestamped `.pyc` files would be stale) adds
  6.9 MiB to the compressed `deps` layer and saves 0.8 s: `/readyz` is up 1.3 s after the container starts, not 2.1 s.
* Removed after the install: `direct_url.json` (it names this host's wheel paths), `INSTALLER`, `REQUESTED`, `bin/`
  (console scripts whose shebangs name this host's Python) and `copilot/bin`, should a platform wheel of the SDK bundle
  the Copilot CLI there (the pinned universal wheel does not, so the guard saves nothing today).
* Django's 1,226 translation catalogs (`LC_MESSAGES`) are pruned too: 16.9 to 13.4 MiB compressed. `USE_I18N` is off,
  so none is ever opened; keep them if you turn it on. `django/conf/locale` is code Django imports, so it stays.

## Run it

After `make up` from the repository root, run `make run` **in this directory** to build, publish,
deploy and smoke-test this agent. Use `./build.sh` to build just the artifact.

From the repository root:

```bash
make agent AGENT=python-django      # build, publish, deploy, smoke test (make auth for the /ask checks)
make ask AGENT=python-django Q="Which language runtime are you on and where is it installed?"
# I'm running on CPython 3.13.5. The tool reports its home as `/usr`.
kubectl -n agents port-forward deploy/python-django 18302:8080 &      # or call it directly:
curl -s localhost:18302/ask -H 'content-type: application/json' -d '{"question":"Which web framework are you on?"}'
# {"answer": "I'm running on Django 6.0.10. The agent is named ...", "conversationId": "c5f6073b-..."}
```

## Gotchas

* **`built_in_tools=False` is not enough.** It only adds `builtin:*` to the deny-list: the shell and file tools
  disappear, but the Copilot CLI's own GitHub MCP tools (`github-mcp-server-*`, which can read repositories with the
  sidecar's token) and `web_search` stay listed and callable. `available_tools = ["custom:runtime_facts"]` is an
  allow-list over every tool source, and the model then lists only `runtime_facts`. The integration rejects combining
  it with `built_in_tools=False` or `excluded_tools`, and requires it to name the agent's own tool (`custom:*` works
  too). `make smoke` asks the model to list its tools and fails if a GitHub, web or shell tool shows up.
* **Empty session mode.** Sessions start with `mode: "empty"` (no default prompt or tools), so each must name its
  tools. The integration also sends this process's working directory, which the sidecar's filesystem lacks
  (`working_directory` returns nothing), and creates its state directory even when it only attaches (`/tmp`).
* **API-only Django.** `DEBUG=False`, `DATABASES={}`, no static files or templates and `MIDDLEWARE=[]`: the API is
  stateless, so there are no sessions, cookies, CSRF forms or signed values, and `SECRET_KEY` is `DJANGO_SECRET_KEY`
  when set and a random key per process otherwise. Django's `check --deploy` therefore warns three times
  (`security.W001` to `W003`: no security, clickjacking or CSRF middleware).
* **`ALLOWED_HOSTS = ["*"]`.** Requests carry the Pod IP (kubelet probes) or the Service name as their `Host`, and
  neither is known at build time. Fine for this internal demo; `DJANGO_ALLOWED_HOSTS` (comma separated) narrows it.
* **JSON errors.** Django's error pages are HTML, so `handler400`/`404`/`500` answer the contract's `{"error",
  "message"}`; a wrong method gets Django's own `405` with an empty body.
* **The integration never reconnects.** The core runtime caches its SDK client for good and the SDK only starts a
  client that has none, so after a sidecar restart the dead connection is reused: `/readyz` stays 503 while `/healthz`
  stays 200, and the kubelet never restarts the agent. `SidecarProbe` calls `client.start()` before each probe (a
  no-op while connected), so `/readyz` is back 1-2 s after a restart. The core should reset its client when it drops.
* **Conversation ids.** The sidecar only accepts session ids of `[A-Za-z0-9_-]`; the integration hashes the
  conversation id into one, so every character the contract allows (`.`, `:`, `/`) works and `/ask` echoes the id.
