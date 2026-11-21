using CopilotSdk.Extensions.Hosting;
using Microsoft.Copilot;

namespace BrewletAgents.Concierge;

/// <summary>
/// Lets a request pick the id of the Copilot session it creates. The integration's chat client resumes the
/// session named by <c>ChatOptions.ConversationId</c>, or creates one under an id of the SDK's choosing; the
/// session configuration hook is the only place where the id of a new session can still be set.
/// </summary>
internal static class NewSessionId
{
    private static readonly AsyncLocal<string?> Pending = new();

    /// <summary>Names the session that the current async flow is about to create.</summary>
    public static void Use(string sessionId) => Pending.Value = sessionId;

    /// <summary>Registered with <see cref="CopilotOptions.ConfigureSession"/>; resumed sessions already have their id.</summary>
    public static void Apply(SessionOptionsBase session)
    {
        if (session is CreateSessionOptions create && Pending.Value is { } sessionId)
        {
            create.SessionId = sessionId;
        }
    }
}
