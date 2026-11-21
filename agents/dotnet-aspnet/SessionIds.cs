using System.Security.Cryptography;
using System.Text;

namespace BrewletAgents.Concierge;

/// <summary>
/// Names the Copilot session of a conversation. The sidecar accepts session ids of <c>[A-Za-z0-9_-]</c> only, while
/// the contract's conversation ids may also contain '.', ':' and '/', so the session id is derived from the
/// conversation id instead of reusing it, as the Java, Node and Python integrations do.
/// </summary>
internal static class SessionIds
{
    private const string Prefix = "concierge-";

    /// <summary>The prefix and the lowercase hex SHA-256 of the UTF-8 bytes of <paramref name="conversationId"/>.</summary>
    public static string For(string conversationId) =>
        Prefix + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(conversationId)));
}
