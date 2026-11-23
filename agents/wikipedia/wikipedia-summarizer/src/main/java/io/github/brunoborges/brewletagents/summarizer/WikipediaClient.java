package io.github.brunoborges.brewletagents.summarizer;

import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpResponse.BodyHandlers;
import java.nio.charset.StandardCharsets;
import java.util.List;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.json.JsonMapper;

/**
 * Reads the plain text of an article from the MediaWiki Action API of the article's own wiki. The host comes from a
 * validated {@link WikipediaUrl}, redirects are not followed and the response is read only up to a size limit, so a
 * request can neither be steered to another server nor make the app buffer an unbounded body.
 */
@Component
class WikipediaClient implements ArticleSource {

    private static final Logger log = LoggerFactory.getLogger(WikipediaClient.class);

    private final SummarizerProperties.Wikipedia settings;
    private final JsonMapper json;
    private final String apiUrlTemplate;
    private final HttpClient http;

    @Autowired
    WikipediaClient(SummarizerProperties properties, JsonMapper json) {
        this(properties.wikipedia(), json, "https://%s/w/api.php");
    }

    /** @param apiUrlTemplate the API address with the wiki's host in place of {@code %s}; a test points it at a local server */
    WikipediaClient(SummarizerProperties.Wikipedia settings, JsonMapper json, String apiUrlTemplate) {
        this.settings = settings;
        this.json = json;
        this.apiUrlTemplate = apiUrlTemplate;
        this.http = HttpClient.newBuilder()
                .connectTimeout(settings.timeout())
                .followRedirects(HttpClient.Redirect.NEVER)
                .build();
    }

    @Override
    public Article fetch(WikipediaUrl article) {
        String query = "action=query&format=json&formatversion=2&prop=extracts&explaintext=1&redirects=1&titles="
                + URLEncoder.encode(article.title(), StandardCharsets.UTF_8);
        HttpRequest request = HttpRequest.newBuilder(URI.create(apiUrlTemplate.formatted(article.host()) + "?" + query))
                .timeout(settings.timeout())
                .header("User-Agent", settings.userAgent())
                .header("Accept", "application/json")
                .GET()
                .build();
        HttpResponse<byte[]> response;
        try {
            response = http.send(request, BodyHandlers.limiting(BodyHandlers.ofByteArray(), settings.maxResponseBytes()));
        } catch (IOException e) {
            log.warn("reading {} failed", request.uri().getHost(), e);
            throw unavailable("could not read the article from " + article.host());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw unavailable("the request was interrupted");
        }
        if (response.statusCode() != 200) {
            throw unavailable(article.host() + " answered HTTP " + response.statusCode());
        }
        return parse(response.body(), article);
    }

    private Article parse(byte[] body, WikipediaUrl article) {
        ApiResponse response;
        try {
            response = json.readValue(body, ApiResponse.class);
        } catch (JacksonException e) {
            throw unavailable(article.host() + " returned something that is not JSON");
        }
        if (response == null || response.error() != null) {
            throw unavailable(article.host() + " rejected the request");
        }
        List<Page> pages = response.query() == null ? null : response.query().pages();
        Page page = pages == null || pages.isEmpty() ? null : pages.get(0);
        if (page == null || Boolean.TRUE.equals(page.missing()) || Boolean.TRUE.equals(page.invalid())) {
            throw new ApiException(HttpStatus.NOT_FOUND, "article_not_found",
                    "there is no article titled \"" + article.title() + "\" on " + article.host());
        }
        if (page.extract() == null || page.extract().isBlank()) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "no_article_text",
                    "\"" + page.title() + "\" has no text to summarize");
        }
        return new Article(page.title(), page.extract().strip());
    }

    private static ApiException unavailable(String message) {
        return new ApiException(HttpStatus.BAD_GATEWAY, "wikipedia_unavailable", message);
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    record ApiResponse(Query query, ApiError error) {
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    record Query(List<Page> pages) {
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    record ApiError(String code) {
    }

    @JsonIgnoreProperties(ignoreUnknown = true)
    record Page(String title, String extract, Boolean missing, Boolean invalid) {
    }
}
