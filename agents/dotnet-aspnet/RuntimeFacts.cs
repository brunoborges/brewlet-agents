using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using CopilotSdk.Extensions.Hosting;
using Microsoft.Copilot;

namespace BrewletAgents.Concierge;

/// <summary>
/// The facts the Runtime Concierge reports, both over GET /runtime and to the model through the runtime_facts tool.
/// Everything is read from the live process, so the answer shows what Brewlet actually launched.
/// </summary>
public sealed class RuntimeFacts(SidecarProbe sidecar, IConfiguration configuration)
{
    public async Task<JsonObject> DescribeAsync(CancellationToken cancellationToken) => new()
    {
        ["agent"] = Agent(),
        ["language"] = Language(),
        ["copilot"] = new JsonObject
        {
            ["sdk"] = Library(typeof(CopilotClient).Assembly),
            ["integration"] = Library(typeof(CopilotOptions).Assembly),
            ["cli"] = await sidecar.DescribeAsync(cancellationToken),
        },
        ["deployment"] = Deployment(),
    };

    /// <summary>
    /// The facts as flat <c>dotted.key: value</c> lines, which is what the model reads: the whole document for
    /// "all" or an unknown topic, otherwise just that part.
    /// </summary>
    public static string ToText(JsonObject facts, string? topic)
    {
        var wanted = topic?.Trim().ToLowerInvariant() ?? "all";
        if (wanted != "all" && facts[wanted] is { } part)
        {
            facts = new JsonObject { [wanted] = part.DeepClone() };
        }

        var text = new StringBuilder();
        Flatten(string.Empty, facts, text);
        return text.ToString();
    }

    private JsonObject Agent() => new()
    {
        ["name"] = configuration["AGENT_NAME"] ?? "dotnet-aspnet",
        ["framework"] = new JsonObject
        {
            ["name"] = "ASP.NET Core",
            ["version"] = VersionOf(typeof(WebApplication).Assembly),
        },
        ["location"] = Assembly.GetEntryAssembly()?.Location ?? "unknown",
    };

    private static JsonObject Language() => new()
    {
        ["name"] = "dotnet",
        ["version"] = Environment.Version.ToString(3),
        ["vendor"] = "Microsoft",
        ["home"] = Path.TrimEndingDirectorySeparator(RuntimeEnvironment.GetRuntimeDirectory()),
    };

    private JsonObject Deployment() => new()
    {
        ["runtimeId"] = configuration["AGENT_RUNTIME_ID"] ?? "unknown",
        ["pod"] = configuration["POD_NAME"] ?? configuration["HOSTNAME"] ?? "unknown",
        ["namespace"] = configuration["POD_NAMESPACE"] ?? "unknown",
        ["node"] = configuration["NODE_NAME"] ?? "unknown",
    };

    private static JsonObject Library(Assembly assembly) => new()
    {
        ["name"] = assembly.GetName().Name,
        ["version"] = VersionOf(assembly),
        ["location"] = assembly.Location,
    };

    // The informational version carries a "+<commit>" suffix that does not belong in a version number.
    private static string VersionOf(Assembly assembly)
    {
        var version = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString(3)
            ?? "unknown";
        var metadata = version.IndexOf('+');
        return metadata < 0 ? version : version[..metadata];
    }

    private static void Flatten(string prefix, JsonObject values, StringBuilder text)
    {
        foreach (var (key, value) in values)
        {
            var name = prefix.Length == 0 ? key : $"{prefix}.{key}";
            if (value is JsonObject nested)
            {
                Flatten(name, nested, text);
            }
            else
            {
                text.Append(name).Append(": ").Append(value?.ToString() ?? "null").Append('\n');
            }
        }
    }
}
