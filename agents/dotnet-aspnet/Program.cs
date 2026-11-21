using BrewletAgents.Concierge;
using CopilotSdk.Extensions.Hosting;

var builder = WebApplication.CreateBuilder(args);

// The Copilot CLI runs in the sidecar container of the same Pod. Both values come from the Pod spec
// and have deliberately no defaults, so a misconfigured Pod fails at startup.
var cliUrl = Required("COPILOT_CLI_URL");
var connectionToken = Required("COPILOT_CONNECTION_TOKEN");

// PORT is the Pod's contract with the Service. The runtime image's ASPNETCORE_HTTP_PORTS only holds the same
// setting's default, so replace its value rather than add a second binding, which would log a warning.
builder.Configuration["HTTP_PORTS"] = builder.Configuration.GetValue("PORT", 8080).ToString();

// Questions are at most 4000 characters, so nothing legitimate comes close to this.
builder.WebHost.ConfigureKestrel(kestrel => kestrel.Limits.MaxRequestBodySize = 64 * 1024);

builder.Services
    .AddCopilot(copilot =>
    {
        copilot.Endpoint = cliUrl;
        copilot.ConnectionToken = connectionToken;
        copilot.Instructions = ConciergeAgent.LoadInstructions();
        copilot.ConfigureSession(NewSessionId.Apply);
    })
    // The model's only tool: the client runs in "empty" mode, so there is no shell, file or web access.
    .WithTools<RuntimeFactsTool>();

builder.Services.AddSingleton<SidecarProbe>();
builder.Services.AddSingleton<RuntimeFacts>();
builder.Services.AddSingleton<ConciergeAgent>();

var app = builder.Build();
app.MapConciergeEndpoints();
app.Run();

string Required(string name) =>
    builder.Configuration[name] is { Length: > 0 } value
        ? value
        : throw new InvalidOperationException($"{name} is required: the Pod spec provides it");
