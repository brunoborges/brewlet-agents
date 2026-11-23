package io.github.brunoborges.brewletagents.summarizer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import com.microsoft.copilot.integrations.core.CopilotSessionMessage;
import com.microsoft.copilot.integrations.core.CopilotSessionStore;
import com.microsoft.copilot.rpc.SessionMetadata;
import io.micrometer.observation.Observation;
import io.micrometer.observation.ObservationHandler;
import io.micrometer.observation.ObservationRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

class SummaryServiceTest {

    private static final String URL = "https://en.wikipedia.org/wiki/Java_(programming_language)";
    private static final ArticleSource.Article JAVA = new ArticleSource.Article("Java (programming language)",
            "Java is a language.\n\n== History ==\nIt began in 1991.");
    private static final Pattern OPENING_MARKER = Pattern.compile("<<<ARTICLE (\\w+)>>>");

    private final FakeSessions sessions = new FakeSessions();
    private final AtomicInteger fetches = new AtomicInteger();
    private final AtomicReference<String> conversationId = new AtomicReference<>();
    private final AtomicReference<String> request = new AtomicReference<>();
    private final List<String> observed = new ArrayList<>();
    private final ObservationRegistry observations = ObservationRegistry.create();
    private boolean authenticated = true;
    private boolean sidecarDown;
    private int maxArticleChars = 60_000;
    private Duration modelTimeout = Duration.ofSeconds(5);
    private ArticleSource.Article article = JAVA;
    private ArticleSummarizer model = answer("A language.\n\nKey points\n- 1991");

    SummaryServiceTest() {
        observations.observationConfig().observationHandler(new ObservationHandler<Observation.Context>() {
            @Override
            public boolean supportsContext(Observation.Context context) {
                return true;
            }

            @Override
            public void onStop(Observation.Context context) {
                observed.add(context.getName() + (context.getError() == null ? "" : " failed"));
            }
        });
    }

    @Test
    void summarizesTheArticleAndForgetsTheConversation() {
        SummaryService.Summary summary = service().summarize(URL);

        assertThat(summary).isEqualTo(new SummaryService.Summary(
                URL, "Java (programming language)", "A language.\n\nKey points\n- 1991", false));
        assertThat(sessions.deleted).containsExactly("agent-" + conversationId.get());

        Matcher marker = OPENING_MARKER.matcher(request.get());
        assertThat(marker.find()).isTrue();
        assertThat(request.get()).contains("Title: Java (programming language)\n\n" + JAVA.text()
                + "\n<<<END ARTICLE " + marker.group(1) + ">>>");
    }

    @Test
    void observesTheArticleFetchAndTheModelCall() {
        service().summarize(URL);

        assertThat(observed).containsExactly("summarizer.fetch", "summarizer.model");
    }

    @Test
    void resolvesRedirectsInTheReturnedAddress() {
        article = new ArticleSource.Article("Java", "Java is an island.");

        SummaryService.Summary summary = service().summarize("https://en.wikipedia.org/wiki/Java_island");

        assertThat(summary.title()).isEqualTo("Java");
        assertThat(summary.url()).isEqualTo("https://en.wikipedia.org/wiki/Java");
    }

    @Test
    void sendsOnlyTheBeginningOfALongArticle() {
        maxArticleChars = 100;
        article = new ArticleSource.Article("Long", "a".repeat(95) + "\n" + "b".repeat(400));

        SummaryService.Summary summary = service().summarize("https://en.wikipedia.org/wiki/Long");

        assertThat(summary.truncated()).isTrue();
        assertThat(request.get()).contains("only its first 95 characters").contains("a".repeat(95))
                .doesNotContain("b".repeat(10));
    }

    @Test
    void everyRequestCarriesItsOwnMarkerToken() {
        String first = SummaryService.request("T", "text", false);
        String second = SummaryService.request("T", "text", false);

        Matcher a = OPENING_MARKER.matcher(first);
        Matcher b = OPENING_MARKER.matcher(second);
        assertThat(a.find() && b.find()).isTrue();
        assertThat(a.group(1)).isNotEqualTo(b.group(1));
    }

    @Test
    void cutsAtAParagraphBreakWhenOneIsNearTheLimit() {
        String text = "x".repeat(95) + "\n" + "y".repeat(50);

        assertThat(SummaryService.truncate(text, 100)).isEqualTo("x".repeat(95));
        assertThat(SummaryService.truncate("x".repeat(10) + "\n" + "y".repeat(200), 100)).hasSize(100);
        assertThat(SummaryService.truncate("short", 100)).isEqualTo("short");
    }

    @Test
    void neverCutsInsideASurrogatePair() {
        String text = "a".repeat(9) + "\uD83D\uDE00" + "b";

        assertThat(SummaryService.truncate(text, 10)).isEqualTo("a".repeat(9));
    }

    @Test
    void refusesToFetchOrAskWhileTheSidecarHasNoCredentials() {
        authenticated = false;

        assertFailure(HttpStatus.SERVICE_UNAVAILABLE, "copilot_not_authenticated");
        assertThat(fetches).hasValue(0);
        assertThat(request.get()).isNull();
    }

    @Test
    void reportsAnUnreachableSidecar() {
        sidecarDown = true;

        assertFailure(HttpStatus.SERVICE_UNAVAILABLE, "copilot_unavailable");
    }

    @Test
    void reportsAModelFailureAndStillForgetsTheConversation() {
        model = (id, text) -> {
            conversationId.set(id);
            return CompletableFuture.failedFuture(new IllegalStateException("model exploded"));
        };

        assertFailure(HttpStatus.BAD_GATEWAY, "agent_error");
        assertThat(sessions.deleted).containsExactly("agent-" + conversationId.get());
        assertThat(observed).containsExactly("summarizer.fetch", "summarizer.model failed");
    }

    @Test
    void reportsATimeoutAndStillForgetsTheConversation() {
        modelTimeout = Duration.ofMillis(50);
        model = (id, text) -> {
            conversationId.set(id);
            return new CompletableFuture<>();
        };

        assertFailure(HttpStatus.GATEWAY_TIMEOUT, "timeout");
        assertThat(sessions.deleted).containsExactly("agent-" + conversationId.get());
    }

    @Test
    void doesNotFailTheRequestWhenTheSessionCannotBeDeleted() {
        sessions.failing = true;

        assertThat(service().summarize(URL).summary()).startsWith("A language.");
    }

    private void assertFailure(HttpStatus status, String code) {
        assertThatThrownBy(() -> service().summarize(URL)).isInstanceOfSatisfying(ApiException.class, e -> {
            assertThat(e.status()).isEqualTo(status);
            assertThat(e.code()).isEqualTo(code);
        });
    }

    private ArticleSummarizer answer(String text) {
        return (id, message) -> {
            conversationId.set(id);
            request.set(message);
            return CompletableFuture.completedFuture(text);
        };
    }

    private SummaryService service() {
        ArticleSource source = url -> {
            fetches.incrementAndGet();
            return article;
        };
        SidecarProbe sidecar = new SidecarProbe(null) {
            @Override
            boolean isAuthenticated() {
                if (sidecarDown) {
                    throw new SidecarException("down", null);
                }
                return authenticated;
            }
        };
        var wikipedia = new SummarizerProperties.Wikipedia(maxArticleChars, 1024, Duration.ofSeconds(1), "test");
        return new SummaryService(source, model, sessions, sidecar, new SummarizerProperties(modelTimeout, wikipedia),
                observations);
    }

    private static final class FakeSessions implements CopilotSessionStore {
        final List<String> deleted = new ArrayList<>();
        boolean failing;

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
            if (failing) {
                throw new IllegalStateException("CLI unreachable");
            }
            return deleted.add(sessionId);
        }

        @Override
        public String sessionId(Class<?> agentType, String conversationId) {
            return "agent-" + conversationId;
        }
    }
}
