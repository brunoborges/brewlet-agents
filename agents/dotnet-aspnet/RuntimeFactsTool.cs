using System.ComponentModel;

namespace BrewletAgents.Concierge;

/// <summary>
/// The model's only tool. The integration discovers the public methods that carry a description and names
/// them in snake_case without the Async suffix: this one is <c>runtime_facts</c>.
/// </summary>
public sealed class RuntimeFactsTool(RuntimeFacts facts)
{
    [Description("Verified facts about the environment this agent runs in: the .NET runtime (version, home directory),"
        + " the application artifact (framework, code location), the Copilot SDK and integration versions, the Copilot"
        + " CLI sidecar (version, authentication) and the Kubernetes/Brewlet deployment (runtime image id, pod)."
        + " Call it before answering any question about these.")]
    public async Task<string> RuntimeFactsAsync(
        [Description("Which part to return: all, language, agent, copilot or deployment")] string topic = "all",
        CancellationToken cancellationToken = default) =>
        RuntimeFacts.ToText(await facts.DescribeAsync(cancellationToken), topic);
}
