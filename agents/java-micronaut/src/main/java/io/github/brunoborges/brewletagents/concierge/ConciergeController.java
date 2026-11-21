package io.github.brunoborges.brewletagents.concierge;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.regex.Pattern;

import io.micronaut.core.annotation.Nullable;
import io.micronaut.http.HttpResponse;
import io.micronaut.http.HttpStatus;
import io.micronaut.http.annotation.Body;
import io.micronaut.http.annotation.Controller;
import io.micronaut.http.annotation.Get;
import io.micronaut.http.annotation.Post;
import io.micronaut.scheduling.TaskExecutors;
import io.micronaut.scheduling.annotation.ExecuteOn;
import io.micronaut.serde.annotation.Serdeable;

/** The Runtime Concierge contract that every agent in this repository implements, whatever its language. */
@Controller
public class ConciergeController {

    private static final Pattern CONVERSATION_ID = Pattern.compile("[A-Za-z0-9._:/-]{1,128}");
    private static final int MAX_QUESTION_LENGTH = 4000;

    private final ConciergeAgent agent;
    private final SidecarProbe sidecar;
    private final RuntimeFacts facts;

    public ConciergeController(ConciergeAgent agent, SidecarProbe sidecar, RuntimeFacts facts) {
        this.agent = agent;
        this.sidecar = sidecar;
        this.facts = facts;
    }

    @Serdeable.Deserializable
    public record AskRequest(@Nullable String question, @Nullable String conversationId) {
    }

    @Get("/healthz")
    public Map<String, String> healthz() {
        return Map.of("status", "UP");
    }

    // The routes below wait on the sidecar, so they run on the blocking executor, not on the event loop.
    @Get("/readyz")
    @ExecuteOn(TaskExecutors.BLOCKING)
    public HttpResponse<Map<String, String>> readyz() {
        if (sidecar.isReachable()) {
            return HttpResponse.ok(Map.of("status", "READY"));
        }
        return HttpResponse.<Map<String, String>>status(HttpStatus.SERVICE_UNAVAILABLE)
                .body(Map.of("status", "NOT_READY", "reason", "copilot_cli_unreachable"));
    }

    @Get("/runtime")
    @ExecuteOn(TaskExecutors.BLOCKING)
    public Map<String, Object> runtime() {
        return facts.describe();
    }

    @Post("/ask")
    @ExecuteOn(TaskExecutors.BLOCKING)
    public HttpResponse<Map<String, Object>> ask(@Body AskRequest request) throws InterruptedException {
        String question = request.question();
        if (question == null || question.isBlank() || question.length() > MAX_QUESTION_LENGTH) {
            return error(HttpStatus.BAD_REQUEST, "bad_request",
                    "question is required and must be at most " + MAX_QUESTION_LENGTH + " characters");
        }
        String conversationId = request.conversationId() == null ? UUID.randomUUID().toString() : request.conversationId();
        if (!CONVERSATION_ID.matcher(conversationId).matches()) {
            return error(HttpStatus.BAD_REQUEST, "bad_request", "conversationId must match " + CONVERSATION_ID.pattern());
        }
        try {
            if (!sidecar.isAuthenticated()) {
                return error(HttpStatus.SERVICE_UNAVAILABLE, "copilot_not_authenticated",
                        "the Copilot CLI sidecar has no GitHub credentials; see docs/authentication.md");
            }
        } catch (SidecarProbe.SidecarException e) {
            return error(HttpStatus.SERVICE_UNAVAILABLE, "copilot_unavailable", e.getMessage());
        }
        try {
            String answer = agent.ask(conversationId, question).get(2, TimeUnit.MINUTES);
            Map<String, Object> body = new LinkedHashMap<>();
            body.put("answer", answer);
            body.put("conversationId", conversationId);
            return HttpResponse.ok(body);
        } catch (TimeoutException e) {
            return error(HttpStatus.GATEWAY_TIMEOUT, "timeout", "the model did not answer within 2 minutes");
        } catch (ExecutionException e) {
            return error(HttpStatus.BAD_GATEWAY, "agent_error", String.valueOf(e.getCause().getMessage()));
        }
    }

    private static HttpResponse<Map<String, Object>> error(HttpStatus status, String code, String message) {
        return HttpResponse.<Map<String, Object>>status(status).body(Map.of("error", code, "message", message));
    }
}
