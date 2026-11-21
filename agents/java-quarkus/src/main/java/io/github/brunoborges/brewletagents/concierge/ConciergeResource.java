package io.github.brunoborges.brewletagents.concierge;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.regex.Pattern;

import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.core.Response.Status;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.exc.MismatchedInputException;
import io.smallrye.common.annotation.NonBlocking;
import io.smallrye.common.annotation.RunOnVirtualThread;
import org.jboss.resteasy.reactive.RestResponse;
import org.jboss.resteasy.reactive.server.ServerExceptionMapper;

/** The Runtime Concierge contract that every agent in this repository implements, whatever its language. */
@Path("/")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class ConciergeResource {

    private static final Pattern CONVERSATION_ID = Pattern.compile("[A-Za-z0-9._:/-]{1,128}");
    private static final int MAX_QUESTION_LENGTH = 4000;
    private static final long ASK_TIMEOUT_MINUTES = 2;

    private final ConciergeAgent agent;
    private final SidecarProbe sidecar;
    private final RuntimeFacts facts;

    ConciergeResource(ConciergeAgent agent, SidecarProbe sidecar, RuntimeFacts facts) {
        this.agent = agent;
        this.sidecar = sidecar;
        this.facts = facts;
    }

    public record AskRequest(String question, String conversationId) {
    }

    /** Runs on the event loop: liveness must answer even when every worker is waiting on the model. */
    @GET
    @Path("/healthz")
    @NonBlocking
    public Map<String, String> healthz() {
        return Map.of("status", "UP");
    }

    // The endpoints below block on the sidecar, so they run on virtual threads.
    @GET
    @Path("/readyz")
    @RunOnVirtualThread
    public RestResponse<Map<String, String>> readyz() {
        if (sidecar.isReachable()) {
            return RestResponse.ok(Map.of("status", "READY"));
        }
        return RestResponse.status(Status.SERVICE_UNAVAILABLE,
                Map.of("status", "NOT_READY", "reason", "copilot_cli_unreachable"));
    }

    @GET
    @Path("/runtime")
    @RunOnVirtualThread
    public Map<String, Object> runtime() {
        return facts.describe();
    }

    @POST
    @Path("/ask")
    @RunOnVirtualThread
    public RestResponse<Map<String, Object>> ask(AskRequest request) {
        String question = request == null ? null : request.question();
        if (question == null || question.isBlank() || question.length() > MAX_QUESTION_LENGTH) {
            return error(Status.BAD_REQUEST, "bad_request",
                    "question is required and must be at most " + MAX_QUESTION_LENGTH + " characters");
        }
        String conversationId = request.conversationId() == null ? UUID.randomUUID().toString() : request.conversationId();
        if (!CONVERSATION_ID.matcher(conversationId).matches()) {
            return error(Status.BAD_REQUEST, "bad_request", "conversationId must match " + CONVERSATION_ID.pattern());
        }
        try {
            if (!sidecar.isAuthenticated()) {
                return error(Status.SERVICE_UNAVAILABLE, "copilot_not_authenticated",
                        "the Copilot CLI sidecar has no GitHub credentials; see docs/authentication.md");
            }
        } catch (SidecarProbe.SidecarException e) {
            return error(Status.SERVICE_UNAVAILABLE, "copilot_unavailable", e.getMessage());
        }
        CompletableFuture<String> reply = agent.ask(conversationId, question);
        try {
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("answer", reply.get(ASK_TIMEOUT_MINUTES, TimeUnit.MINUTES));
            body.put("conversationId", conversationId);
            return RestResponse.ok(body);
        } catch (TimeoutException e) {
            // Cancelling makes the extension abort the turn that is still running in the sidecar.
            reply.cancel(true);
            return timeout();
        } catch (ExecutionException e) {
            // The extension's own response timeout surfaces as a TimeoutException wrapped in the failure.
            return causedByTimeout(e) ? timeout()
                    : error(Status.BAD_GATEWAY, "agent_error", String.valueOf(e.getCause().getMessage()));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            reply.cancel(true);
            return error(Status.SERVICE_UNAVAILABLE, "copilot_unavailable", "interrupted while waiting for the model");
        }
    }

    private static boolean causedByTimeout(Throwable failure) {
        for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
            if (cause instanceof TimeoutException) {
                return true;
            }
        }
        return false;
    }

    private static RestResponse<Map<String, Object>> timeout() {
        return error(Status.GATEWAY_TIMEOUT, "timeout",
                "the model did not answer within " + ASK_TIMEOUT_MINUTES + " minutes");
    }

    private static RestResponse<Map<String, Object>> error(Status status, String code, String message) {
        return RestResponse.status(status, Map.of("error", code, "message", message));
    }

    // Jackson reports malformed JSON as a bare 400 WebApplicationException and a body of the wrong
    // shape as MismatchedInputException; both would otherwise reach the client with an empty body.
    @ServerExceptionMapper
    public Response unreadableBody(WebApplicationException e) {
        return e.getCause() instanceof JsonProcessingException ? notJson().toResponse() : e.getResponse();
    }

    @ServerExceptionMapper
    public RestResponse<Map<String, Object>> mistypedBody(MismatchedInputException e) {
        return notJson();
    }

    private static RestResponse<Map<String, Object>> notJson() {
        return error(Status.BAD_REQUEST, "bad_request", "the request body must be a JSON object such as {\"question\":\"...\"}");
    }
}
