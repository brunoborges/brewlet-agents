package io.github.brunoborges.brewletagents.concierge;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.regex.Pattern;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/** The Runtime Concierge contract that every agent in this repository implements, whatever its language. */
@RestController
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

    public record AskRequest(String question, String conversationId) {
    }

    @GetMapping("/healthz")
    public Map<String, String> healthz() {
        return Map.of("status", "UP");
    }

    @GetMapping("/readyz")
    public ResponseEntity<Map<String, String>> readyz() {
        if (sidecar.isReachable()) {
            return ResponseEntity.ok(Map.of("status", "READY"));
        }
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .body(Map.of("status", "NOT_READY", "reason", "copilot_cli_unreachable"));
    }

    @GetMapping("/runtime")
    public Map<String, Object> runtime() {
        return facts.describe();
    }

    @PostMapping("/ask")
    public ResponseEntity<Map<String, Object>> ask(@RequestBody AskRequest request) throws InterruptedException {
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
            return ResponseEntity.ok(body);
        } catch (TimeoutException e) {
            return error(HttpStatus.GATEWAY_TIMEOUT, "timeout", "the model did not answer within 2 minutes");
        } catch (ExecutionException e) {
            return error(HttpStatus.BAD_GATEWAY, "agent_error", String.valueOf(e.getCause().getMessage()));
        }
    }

    private static ResponseEntity<Map<String, Object>> error(HttpStatus status, String code, String message) {
        return ResponseEntity.status(status).body(Map.of("error", code, "message", message));
    }
}
