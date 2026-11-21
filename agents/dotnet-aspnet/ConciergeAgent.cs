using System.Reflection;
using CopilotSdk.Extensions.Hosting;
using Microsoft.Extensions.AI;

namespace BrewletAgents.Concierge;

/// <summary>
/// Sends each question to the Copilot CLI sidecar through the integration's chat client. Settings and the
/// system prompt are registered in Program.cs; <see cref="SessionIds"/> names the Copilot session of a conversation.
/// </summary>
public sealed class ConciergeAgent(IChatClient chat, ICopilotSessionStore sessions)
{
    private const string PromptResource = "prompts/concierge.md";

    /// <summary>The system prompt, embedded in the assembly so it ships with the code layer.</summary>
    public static string LoadInstructions()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(PromptResource)
            ?? throw new InvalidOperationException($"the embedded prompt {PromptResource} is missing");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    /// <summary>Asks one question; the same <paramref name="conversationId"/> continues the same Copilot session.</summary>
    /// <param name="question">The user's question.</param>
    /// <param name="conversationId">The caller's conversation id, or <see langword="null"/> to start a new one.</param>
    /// <param name="cancellationToken">Cancels the call, for example when the client disconnects.</param>
    /// <returns>The answer and the conversation id: the caller's own, or the one generated for it.</returns>
    public async Task<(string Answer, string ConversationId)> AskAsync(
        string question, string? conversationId, CancellationToken cancellationToken)
    {
        conversationId ??= Guid.NewGuid().ToString();
        var sessionId = SessionIds.For(conversationId);

        var options = new ChatOptions();
        if (await sessions.GetAsync(sessionId, cancellationToken) is not null)
        {
            // The chat client resumes the session that ChatOptions.ConversationId names.
            options.ConversationId = sessionId;
        }
        else
        {
            NewSessionId.Use(sessionId);
        }

        // The response's own ConversationId is the session id: callers only ever see their own.
        var response = await chat.GetResponseAsync(question, options, cancellationToken);
        return (response.Text, conversationId);
    }
}
