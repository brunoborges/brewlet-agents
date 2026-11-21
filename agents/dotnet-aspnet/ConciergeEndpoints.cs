using System.Text.Json;
using System.Text.RegularExpressions;

namespace BrewletAgents.Concierge;

/// <summary>The Runtime Concierge contract that every agent in this repository implements, whatever its language.</summary>
public static class ConciergeEndpoints
{
    private const string ConversationIdPattern = "[A-Za-z0-9._:/-]{1,128}";
    private const int MaxQuestionLength = 4000;

    private static readonly Regex ConversationIdFormat = new($@"\A{ConversationIdPattern}\z", RegexOptions.CultureInvariant);

    public sealed record AskRequest(string? Question, string? ConversationId);

    public static void MapConciergeEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/healthz", () => Results.Json(new { status = "UP" }));

        app.MapGet("/readyz", async (SidecarProbe sidecar, CancellationToken cancellationToken) =>
            await sidecar.IsReachableAsync(cancellationToken)
                ? Results.Json(new { status = "READY" })
                : Results.Json(
                    new { status = "NOT_READY", reason = "copilot_cli_unreachable" },
                    statusCode: StatusCodes.Status503ServiceUnavailable));

        app.MapGet("/runtime", async (RuntimeFacts facts, CancellationToken cancellationToken) =>
            Results.Json(await facts.DescribeAsync(cancellationToken)));

        app.MapPost("/ask", AskAsync);
    }

    private static async Task<IResult> AskAsync(
        HttpRequest http,
        ConciergeAgent agent,
        SidecarProbe sidecar,
        ILogger<ConciergeAgent> log,
        CancellationToken cancellationToken)
    {
        AskRequest? request;
        try
        {
            request = await JsonSerializer.DeserializeAsync<AskRequest>(http.Body, JsonSerializerOptions.Web, cancellationToken);
        }
        catch (JsonException)
        {
            request = null;
        }

        if (request is null)
        {
            return Error(StatusCodes.Status400BadRequest, "bad_request", "the request body must be a JSON object with a question");
        }

        var question = request.Question;
        if (string.IsNullOrWhiteSpace(question) || question.Length > MaxQuestionLength)
        {
            return Error(StatusCodes.Status400BadRequest, "bad_request",
                $"question is required and must be at most {MaxQuestionLength} characters");
        }

        if (request.ConversationId is { } id && !ConversationIdFormat.IsMatch(id))
        {
            return Error(StatusCodes.Status400BadRequest, "bad_request", $"conversationId must match {ConversationIdPattern}");
        }

        try
        {
            if (!await sidecar.IsAuthenticatedAsync(cancellationToken))
            {
                return Error(StatusCodes.Status503ServiceUnavailable, "copilot_not_authenticated",
                    "the Copilot CLI sidecar has no GitHub credentials; see docs/authentication.md");
            }
        }
        catch (SidecarException e)
        {
            return Error(StatusCodes.Status503ServiceUnavailable, "copilot_unavailable", e.Message);
        }

        try
        {
            var (answer, conversationId) = await agent.AskAsync(question, request.ConversationId, cancellationToken);
            return Results.Json(new { answer, conversationId });
        }
        catch (TimeoutException)
        {
            return Error(StatusCodes.Status504GatewayTimeout, "timeout", "the model did not answer within 2 minutes");
        }
        catch (Exception e) when (!(e is OperationCanceledException && cancellationToken.IsCancellationRequested))
        {
            log.LogWarning(e, "the Copilot call failed");
            return Error(StatusCodes.Status502BadGateway, "agent_error", e.Message);
        }
    }

    private static IResult Error(int status, string code, string message) =>
        Results.Json(new { error = code, message }, statusCode: status);
}
