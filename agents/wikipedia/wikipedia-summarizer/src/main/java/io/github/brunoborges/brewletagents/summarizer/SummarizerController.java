package io.github.brunoborges.brewletagents.summarizer;

import java.util.Map;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/** The whole public surface of the app: one operation, plus the two probes Kubernetes uses. */
@RestController
class SummarizerController {

    /** @param url an article address, https://&lt;language&gt;.wikipedia.org/wiki/&lt;title&gt; */
    record SummaryRequest(String url) {
    }

    private final SummaryService service;
    private final SidecarProbe sidecar;

    SummarizerController(SummaryService service, SidecarProbe sidecar) {
        this.service = service;
        this.sidecar = sidecar;
    }

    @PostMapping("/api/summaries")
    SummaryService.Summary summarize(@RequestBody SummaryRequest request) {
        return service.summarize(request == null ? null : request.url());
    }

    @GetMapping("/healthz")
    Map<String, String> healthz() {
        return Map.of("status", "UP");
    }

    @GetMapping("/readyz")
    ResponseEntity<Map<String, String>> readyz() {
        if (sidecar.isReachable()) {
            return ResponseEntity.ok(Map.of("status", "READY"));
        }
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .body(Map.of("status", "NOT_READY", "reason", "copilot_cli_unreachable"));
    }
}
