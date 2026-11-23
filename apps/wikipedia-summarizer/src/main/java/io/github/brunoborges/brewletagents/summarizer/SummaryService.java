package io.github.brunoborges.brewletagents.summarizer;

import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import com.microsoft.copilot.integrations.core.CopilotSessionStore;
import io.micrometer.observation.Observation;
import io.micrometer.observation.ObservationRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

/**
 * Fetches an article, has the model summarize it and cleans up the one-off Copilot session afterwards. The two slow
 * steps are observations, so each request shows up in the traces and the metrics of the OpenTelemetry dashboard as
 * the time spent on Wikipedia and the time spent on the model.
 */
@Service
class SummaryService {

    private static final Logger log = LoggerFactory.getLogger(SummaryService.class);

    /**
     * @param url the article's public address after redirects
     * @param truncated whether the article was longer than the limit, so the summary covers only its beginning
     */
    record Summary(String url, String title, String summary, boolean truncated) {
    }

    private final ArticleSource articles;
    private final ArticleSummarizer summarizer;
    private final CopilotSessionStore sessions;
    private final SidecarProbe sidecar;
    private final int maxArticleChars;
    private final Duration modelTimeout;
    private final ObservationRegistry observations;

    SummaryService(ArticleSource articles, ArticleSummarizer summarizer, CopilotSessionStore sessions,
            SidecarProbe sidecar, SummarizerProperties properties, ObservationRegistry observations) {
        this.articles = articles;
        this.summarizer = summarizer;
        this.sessions = sessions;
        this.sidecar = sidecar;
        this.maxArticleChars = properties.wikipedia().maxArticleChars();
        this.modelTimeout = properties.modelTimeout();
        this.observations = observations;
    }

    Summary summarize(String rawUrl) {
        WikipediaUrl url = WikipediaUrl.parse(rawUrl);
        requireAuthenticatedSidecar();
        // Only the wiki's host is recorded: which article somebody asked for stays out of the telemetry.
        ArticleSource.Article article = Observation.createNotStarted("summarizer.fetch", observations)
                .contextualName("fetch article")
                .lowCardinalityKeyValue("wikipedia.host", url.host())
                .observe(() -> articles.fetch(url));
        String text = truncate(article.text(), maxArticleChars);
        boolean truncated = text.length() < article.text().length();
        String summary = Observation.createNotStarted("summarizer.model", observations)
                .contextualName("ask model")
                .lowCardinalityKeyValue("summarizer.truncated", String.valueOf(truncated))
                .observe(() -> ask(request(article.title(), text, truncated)));
        if (summary == null || summary.isBlank()) {
            throw new ApiException(HttpStatus.BAD_GATEWAY, "agent_error", "the model returned an empty summary");
        }
        return new Summary(url.canonicalUrl(article.title()), article.title(), summary.strip(), truncated);
    }

    private void requireAuthenticatedSidecar() {
        try {
            if (!sidecar.isAuthenticated()) {
                throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "copilot_not_authenticated",
                        "the Copilot CLI sidecar has no GitHub credentials; see docs/authentication.md");
            }
        } catch (SidecarProbe.SidecarException e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "copilot_unavailable", e.getMessage(), e);
        }
    }

    /** Every request is its own conversation: nothing the model has seen about one article leaks into the next. */
    private String ask(String request) {
        String conversationId = UUID.randomUUID().toString();
        CompletableFuture<String> reply = summarizer.summarize(conversationId, request);
        try {
            return reply.get(modelTimeout.toMillis(), TimeUnit.MILLISECONDS);
        } catch (TimeoutException e) {
            reply.cancel(true);
            throw new ApiException(HttpStatus.GATEWAY_TIMEOUT, "timeout",
                    "the model did not answer within " + modelTimeout.toSeconds() + "s", e);
        } catch (ExecutionException e) {
            throw new ApiException(HttpStatus.BAD_GATEWAY, "agent_error", String.valueOf(e.getCause().getMessage()), e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "interrupted", "the request was interrupted", e);
        } finally {
            forget(conversationId);
        }
    }

    /** Deletes the finished session; the starter's age-based cleanup is the safety net if this fails. */
    private void forget(String conversationId) {
        try {
            sessions.delete(sessions.sessionId(ArticleSummarizer.class, conversationId));
        } catch (RuntimeException e) {
            log.debug("could not delete the Copilot session of conversation {}", conversationId, e);
        }
    }

    /**
     * The article goes to the model between two marker lines that carry a fresh random token. The article is
     * outside data from the model's point of view (the system prompt says so), and no article can contain the
     * closing marker because nobody knows the token before the request is built.
     */
    static String request(String title, String text, boolean truncated) {
        String token = UUID.randomUUID().toString().replace("-", "");
        StringBuilder request = new StringBuilder("Summarize this Wikipedia article.");
        if (truncated) {
            request.append(" The article is longer than the limit, so only its first ")
                    .append(text.length()).append(" characters are included.");
        }
        return request.append("\n<<<ARTICLE ").append(token).append(">>>\n")
                .append("Title: ").append(title).append("\n\n")
                .append(text)
                .append("\n<<<END ARTICLE ").append(token).append(">>>")
                .toString();
    }

    /** Cuts at a paragraph break close to the limit when there is one, and never inside a surrogate pair. */
    static String truncate(String text, int max) {
        if (text.length() <= max) {
            return text;
        }
        int cut = max;
        if (Character.isHighSurrogate(text.charAt(cut - 1))) {
            cut--;
        }
        int paragraph = text.lastIndexOf('\n', cut);
        if (paragraph > cut - max / 10) {
            cut = paragraph;
        }
        return text.substring(0, cut).stripTrailing();
    }
}
