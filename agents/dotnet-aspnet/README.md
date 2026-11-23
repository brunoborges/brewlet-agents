# dotnet-aspnet

ASP.NET Core 10 minimal APIs on .NET 10: the Runtime Concierge as a framework-dependent app on the plain `dotnet-10`
Brewlet runtime, with `CopilotSdk.Extensions.Hosting` talking to the Copilot CLI sidecar. It implements the same
Runtime Concierge contract (`agents/README.md`) as every other agent; `agents/java-spring` is the reference.

## What is in the artifact

```text
/app/Concierge.dll, *.json   layer "code"   the app, its descriptors, appsettings.json; the prompt is embedded
/app/*.dll                   layer "deps"   5 libraries: Microsoft.Copilot.SDK (22 of the 24 MB), the integration,
                                            Microsoft.Extensions.AI (+ Abstractions), System.Numerics.Tensors
launch.json                  launch layer   /usr/bin/dotnet /app/Concierge.dll   (workingDir /app)
```

| layer | compressed |
| --- | --- |
| deps | 6.02 MiB |
| code | 18.2 KiB |
| launch | 229 B |
| whole artifact | 6.04 MiB (23.1 MiB unpacked, linux/arm64) |

Deliberately **not** in it: .NET and ASP.NET Core (`/usr/share/dotnet` comes from the `dotnet-10` runtime image) and
the Copilot CLI (it runs in the sidecar). `Microsoft.Copilot.SDK` would bundle the CLI into the publish output
(`runtimes/<rid>/native/`, 340 MiB), making the artifact about 152 MiB compressed instead of 6; the build keeps it
out and fails if it ever shows up.

Measured on the kind cluster; [`deployment.yaml`](deployment.yaml) asks for 100m CPU, 128Mi, limit 256Mi:

| working set | fresh Pod | after two asks | 32 asks, 8 at a time |
| --- | --- | --- | --- |
| agent | 55 MiB | 95 MiB | 99 MiB (peak 100) |
| Copilot CLI sidecar | 17 MiB | 46 MiB | peak 144 MiB, then 56 MiB |

Kestrel listens within 1 s of the container starting and the Pod is Ready after 3 s. `make agent` from scratch takes
15 to 19 s with a warm NuGet cache, smoke test included; `make footprint` prints the memory numbers.

## How the integration is used

```csharp
// Program.cs: everything is registered once, the integration does the rest
builder.Services
    .AddCopilot(copilot =>
    {
        copilot.Endpoint = cliUrl;                  // COPILOT_CLI_URL: no default, a wrong Pod fails at startup
        copilot.ConnectionToken = connectionToken;  // COPILOT_CONNECTION_TOKEN: same
        copilot.Instructions = ConciergeAgent.LoadInstructions();   // the embedded prompts/concierge.md
        copilot.ConfigureSession(NewSessionId.Apply);               // names the new session, see Gotchas
    })
    .WithTools<RuntimeFactsTool>();                 // the model's only tool
```

The tool's described public methods become tools: `RuntimeFactsAsync` is `runtime_facts`. `/runtime` reads the same
`RuntimeFacts` object, so what the model says and what the endpoint shows cannot drift apart:

```csharp
public sealed class RuntimeFactsTool(RuntimeFacts facts)
{
    [Description("Verified facts about the environment this agent runs in ...")]
    public async Task<string> RuntimeFactsAsync([Description("Which part: all, language, ...")] string topic = "all", ...
```

[`appsettings.json`](appsettings.json) holds the non-secret settings: `Copilot:ResponseTimeout` 2 min,
`Copilot:SessionRetention` 1 h, `HostOptions:ShutdownTimeout` 15 s (below the Pod's 20 s grace; SIGTERM ends in under
a second, exit code 0). [`ConciergeEndpoints`](ConciergeEndpoints.cs) maps the four endpoints, `ConciergeAgent` asks
the integration's `IChatClient` (the Copilot session id is a hash of the conversation id) and `SidecarProbe` talks
to the sidecar through the `CopilotClient` that `AddCopilot` registers.

## Build notes

* Host tools: .NET SDK 10.0.100 or newer and network access to nuget.org. `scripts/integrations/build.sh dotnet` packs
  the integration into `build/integrations/dotnet`, and [`nuget.config`](nuget.config) makes that a local feed through
  a repo-relative path. The version is stamped `1.0.0-g<sha>` so a new pin never meets a stale copy in NuGet's global
  cache; the csproj floats it (`*-*`), because the feed holds exactly that package.
* Framework-dependent and RID-specific: [`build.sh`](build.sh) runs `dotnet restore` and `dotnet publish -r
  linux-arm64|linux-x64 --self-contained false -p:UseAppHost=false` (settings in [`Concierge.csproj`](Concierge.csproj)),
  so only the libraries outside the shared framework ship, split into `deps` and `code` ([`layers`](layers)); any
  unexpected file fails the build.
* Reproducible: `package_artifact` pins the mtimes that Brewlet keeps in layer tarballs and the csproj drops the
  SDK's git-commit stamp, so unchanged sources give the same digest (`sha256:0ff56e2eb3e8...`, whatever the commit, also
  from an empty NuGet cache) and a code-only change keeps the `deps` digest (`27d94e38c644...`).

## Run it

After `make up` from the repository root, run `make run` **in this directory** to build, publish,
deploy and smoke-test this agent. Use `./build.sh` to build just the artifact.

From the repository root:

```bash
make agent AGENT=dotnet-aspnet       # build, publish, deploy, smoke test (make auth for the /ask checks)
make ask AGENT=dotnet-aspnet Q="Which .NET runtime are you on, and where is it installed?"
# I'm running on .NET 10.0.15 (Microsoft). It's installed at `/usr/share/dotnet/shared/Microsoft.NETCore.App/10.0.15`.
kubectl -n agents port-forward deploy/dotnet-aspnet 8080:8080 &                  # or call it directly:
curl -s localhost:8080/ask -H 'content-type: application/json' -d '{"question":"Which web framework are you on?"}'
# {"answer":"I'm running on ASP.NET Core 10.0.15, on .NET 10.0.15.","conversationId":"d31e866f-..."}
```

## Gotchas

* **Lock the model down with an allow-list; excluding the built-in tools is not enough.** On the Java agents
  `built-in-tools: false` left the CLI's own GitHub MCP tools (`github-mcp-server-*`, which can read repositories with
  the sidecar's token) and `web_search` listed and callable. The .NET key is `SessionToolOptions.AvailableTools`
  (`config.Tools.AvailableTools`). The integration always sets it, because the SDK's `Empty` mode requires it, to
  `["custom:runtime_facts"]` on new and resumed sessions, and its default permission handler approves only that tool.
  Nothing to configure, but `ConfigureSession` runs after the integration's configurators: never widen the list there
  or swap it for a deny-list like `ExcludedTools = ["web_fetch"]`. Verified live: the model lists exactly
  `runtime_facts` (3 of 3 runs, also on a resumed session) and refuses `web_search`, GitHub tools and a shell;
  `make smoke` checks it.
* **`HTTP_PORTS`, not `UseUrls`.** The runtime image sets `ASPNETCORE_HTTP_PORTS=8080`, so a second binding through
  `UseUrls` or `ListenAnyIP` logs "Overriding HTTP_PORTS '8080'...". `Program.cs` copies the Pod's `PORT` into the
  `HTTP_PORTS` setting instead, and the startup log has no warnings.
* **The Web SDK's defaults cost memory and files.** Server GC is on (idle working set 93 MiB against 61 MiB with
  `ServerGarbageCollection=false`), and every `*.json`/`*.config` is published as content, `launch.json` included.
* **A RID-specific restore downloads the runtime packs** (.NET and ASP.NET Core, 178 MiB) even when framework-dependent;
  `EnableRuntimePackDownload=false` skips them (empty-cache build 13 s to 8 s, NuGet cache 317 MiB to 139 MiB).
* **The SDK downloads the Copilot CLI at build time** (113 MB) and publishes it. The integration's package reference
  excludes the SDK's build assets (`exclude="Build,Analyzers"`), so a transitive consumer gets none;
  `CopilotSkipCliDownload=true` keeps it that way if anyone adds a direct SDK reference.
* **Conversation ids become hashed session ids.** The sidecar (CLI 1.0.114) accepts session ids of `[A-Za-z0-9_-]`
  only, narrower than the contract's `[A-Za-z0-9._:/-]{1,128}`, and this integration sends the id unchanged (a `.`,
  `:` or `/` came back as 502 `agent_error`). The Java, Node and Python integrations hash it (with the agent's
  identity); this agent does the same, which keeps the contract's syntax: the session is `concierge-` + the lowercase
  hex SHA-256 of the id ([`SessionIds`](SessionIds.cs)), and the response echoes the caller's id. `NewSessionId` names
  a new session from `ConfigureSession` (an `AsyncLocal`); a resume passes it as `ChatOptions.ConversationId`.
* The client connects lazily and the integration's health check does not start it, so `SidecarProbe` calls
  `StartAsync` (idempotent) before every call; otherwise `/readyz` would not reflect the sidecar.
* `dotnet pack -o <dir>` fails on SDK 10.0.401 (MSB1009), so `dotnet.sh` passes `-p:PackageOutputPath`. Request bodies
  are capped at 64 KiB (413 above).
