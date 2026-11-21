using System.Text.Json.Nodes;
using CopilotSdk.Extensions.Hosting;
using Microsoft.Copilot;
using Microsoft.Extensions.Options;

namespace BrewletAgents.Concierge;

/// <summary>The sidecar could not be reached, or did not answer in time.</summary>
public sealed class SidecarException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>Talks to the Copilot CLI sidecar through the SDK client that <c>AddCopilot</c> registered.</summary>
public sealed class SidecarProbe(CopilotClient client, IOptions<CopilotOptions> options)
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(3);

    /// <summary>True when the sidecar answers a ping.</summary>
    public async Task<bool> IsReachableAsync(CancellationToken cancellationToken)
    {
        try
        {
            await CallAsync(ct => client.PingAsync("readyz", ct), cancellationToken);
            return true;
        }
        catch (SidecarException)
        {
            return false;
        }
    }

    /// <exception cref="SidecarException">The sidecar is unreachable.</exception>
    public async Task<bool> IsAuthenticatedAsync(CancellationToken cancellationToken) =>
        (await CallAsync(ct => client.GetAuthStatusAsync(ct), cancellationToken)).IsAuthenticated;

    /// <summary>Live facts about the sidecar; never throws, so /runtime works even when the sidecar is down.</summary>
    public async Task<JsonObject> DescribeAsync(CancellationToken cancellationToken)
    {
        var cli = new JsonObject { ["endpoint"] = options.Value.Endpoint };
        try
        {
            var status = await CallAsync(ct => client.GetStatusAsync(ct), cancellationToken);
            var auth = await CallAsync(ct => client.GetAuthStatusAsync(ct), cancellationToken);
            cli["attached"] = true;
            cli["version"] = status.Version;
            cli["protocolVersion"] = status.ProtocolVersion;
            cli["authenticated"] = auth.IsAuthenticated;
            cli["authType"] = auth.AuthType?.ToString();
        }
        catch (SidecarException e)
        {
            cli["attached"] = false;
            cli["error"] = e.Message;
        }

        return cli;
    }

    // The client connects lazily: StartAsync is cheap once connected and starts anew after a failure, so every
    // call can begin with it and a sidecar that comes up late is picked up by the next probe.
    private async Task<T> CallAsync<T>(Func<CancellationToken, Task<T>> call, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(Timeout);
        try
        {
            return await ConnectAndCallAsync(call, timeout.Token).WaitAsync(Timeout, cancellationToken);
        }
        catch (Exception e) when (e is TimeoutException || (e is OperationCanceledException && !cancellationToken.IsCancellationRequested))
        {
            throw new SidecarException($"no answer from the Copilot CLI sidecar within {Timeout.TotalSeconds:0}s", e);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            throw new SidecarException($"Copilot CLI sidecar is unreachable: {e.GetType().Name}: {e.Message}", e);
        }
    }

    private async Task<T> ConnectAndCallAsync<T>(Func<CancellationToken, Task<T>> call, CancellationToken cancellationToken)
    {
        await client.StartAsync(cancellationToken);
        return await call(cancellationToken);
    }
}
