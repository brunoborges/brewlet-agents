package io.github.brunoborges.brewletagents.summarizer;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.time.Duration;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;

import com.microsoft.copilot.integrations.core.CopilotSessionMessage;
import com.microsoft.copilot.integrations.core.CopilotSessionStore;
import com.microsoft.copilot.rpc.SessionMetadata;
import io.micrometer.observation.ObservationRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

/** The HTTP contract: routes, status codes and the shape of the JSON, with the model and Wikipedia faked. */
class SummarizerApiTest {

    private ArticleSource source = url -> new ArticleSource.Article("Kubernetes", "Kubernetes orchestrates containers.");
    private boolean sidecarReachable = true;

    @Test
    void summarizesAnArticle() throws Exception {
        mvc().perform(post("/api/summaries").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"url\": \"https://en.wikipedia.org/wiki/Kubernetes\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.url").value("https://en.wikipedia.org/wiki/Kubernetes"))
                .andExpect(jsonPath("$.title").value("Kubernetes"))
                .andExpect(jsonPath("$.summary").value("It orchestrates containers."))
                .andExpect(jsonPath("$.truncated").value(false));
    }

    @Test
    void rejectsAnAddressThatIsNotAWikipediaArticle() throws Exception {
        mvc().perform(post("/api/summaries").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"url\": \"https://example.com/wiki/Kubernetes\"}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("bad_request"))
                .andExpect(jsonPath("$.message").isNotEmpty());
    }

    @Test
    void rejectsABodyThatIsNotTheExpectedJson() throws Exception {
        mvc().perform(post("/api/summaries").contentType(MediaType.APPLICATION_JSON).content("{not json"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("bad_request"));
        mvc().perform(post("/api/summaries").contentType(MediaType.APPLICATION_JSON).content("{}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("bad_request"));
    }

    @Test
    void passesOnTheStatusOfAFailedArticleLookup() throws Exception {
        source = url -> {
            throw new ApiException(HttpStatus.NOT_FOUND, "article_not_found", "no such article");
        };

        mvc().perform(post("/api/summaries").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"url\": \"https://en.wikipedia.org/wiki/Nope\"}"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("article_not_found"))
                .andExpect(jsonPath("$.message").value("no such article"));
    }

    @Test
    void doesNotSummarizeOnGet() throws Exception {
        mvc().perform(get("/api/summaries")).andExpect(status().isMethodNotAllowed());
    }

    @Test
    void probesReportLivenessAndTheSidecar() throws Exception {
        MockMvc mvc = mvc();
        mvc.perform(get("/healthz")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("UP"));
        mvc.perform(get("/readyz")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("READY"));

        sidecarReachable = false;
        mvc().perform(get("/readyz")).andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.reason").value("copilot_cli_unreachable"));
    }

    private MockMvc mvc() {
        SidecarProbe sidecar = new SidecarProbe(null) {
            @Override
            boolean isReachable() {
                return sidecarReachable;
            }

            @Override
            boolean isAuthenticated() {
                return true;
            }
        };
        ArticleSummarizer model = (id, request) -> CompletableFuture.completedFuture("It orchestrates containers.");
        var wikipedia = new SummarizerProperties.Wikipedia(60_000, 1024, Duration.ofSeconds(1), "test");
        var service = new SummaryService(source, model, new NoSessions(), sidecar,
                new SummarizerProperties(Duration.ofSeconds(5), wikipedia), ObservationRegistry.NOOP);
        return MockMvcBuilders.standaloneSetup(new SummarizerController(service, sidecar))
                .setControllerAdvice(new ApiExceptionHandler())
                .build();
    }

    private static final class NoSessions implements CopilotSessionStore {
        @Override
        public List<SessionMetadata> list() {
            return List.of();
        }

        @Override
        public Optional<SessionMetadata> get(String sessionId) {
            return Optional.empty();
        }

        @Override
        public Optional<List<CopilotSessionMessage>> messages(String sessionId) {
            return Optional.empty();
        }

        @Override
        public boolean delete(String sessionId) {
            return false;
        }

        @Override
        public String sessionId(Class<?> agentType, String conversationId) {
            return conversationId;
        }
    }
}
