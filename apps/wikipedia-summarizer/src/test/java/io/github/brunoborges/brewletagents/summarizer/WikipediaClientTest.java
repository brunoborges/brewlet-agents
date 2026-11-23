package io.github.brunoborges.brewletagents.summarizer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import tools.jackson.databind.json.JsonMapper;

/** Runs the client against a local server that plays the MediaWiki API. */
class WikipediaClientTest {

    private static final String USER_AGENT = "wikipedia-summarizer-test/1.0";
    private static final WikipediaUrl CPP = WikipediaUrl.parse("https://en.wikipedia.org/wiki/C++");

    private final AtomicReference<String> seenUserAgent = new AtomicReference<>();
    private final AtomicReference<String> seenQuery = new AtomicReference<>();
    private final AtomicInteger redirectTargetHits = new AtomicInteger();
    private HttpServer server;
    private volatile int status;
    private volatile String body;
    private volatile String location;

    @BeforeEach
    void startServer() throws IOException {
        status = 200;
        body = "{}";
        location = null;
        server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.createContext("/w/api.php", exchange -> {
            seenUserAgent.set(exchange.getRequestHeaders().getFirst("User-Agent"));
            seenQuery.set(exchange.getRequestURI().getRawQuery());
            if (location != null) {
                exchange.getResponseHeaders().add("Location", location);
            }
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(status, bytes.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(bytes);
            }
        });
        server.createContext("/elsewhere", exchange -> {
            redirectTargetHits.incrementAndGet();
            exchange.sendResponseHeaders(204, -1);
            exchange.close();
        });
        server.start();
    }

    @AfterEach
    void stopServer() {
        server.stop(0);
    }

    @Test
    void readsTheArticleAndIdentifiesItself() {
        body = """
                {"batchcomplete": true,
                 "warnings": {"extracts": {"warnings": "ignored"}},
                 "query": {"redirects": [{"from": "Cpp", "to": "C++"}],
                           "pages": [{"pageid": 1, "ns": 0, "title": "C++",
                                      "extract": "C++ is a language.\\n\\n== History ==\\nBjarne began it in 1979.\\n"}]}}
                """;

        ArticleSource.Article article = client(1024 * 1024).fetch(CPP);

        assertThat(article.title()).isEqualTo("C++");
        assertThat(article.text()).isEqualTo("C++ is a language.\n\n== History ==\nBjarne began it in 1979.");
        assertThat(seenUserAgent.get()).isEqualTo(USER_AGENT);
        assertThat(seenQuery.get()).contains("titles=C%2B%2B", "redirects=1", "explaintext=1", "prop=extracts");
    }

    @Test
    void reportsAMissingArticleAsNotFound() {
        body = """
                {"batchcomplete": true, "query": {"pages": [{"title": "C++", "missing": true}]}}
                """;

        assertFailure(HttpStatus.NOT_FOUND, "article_not_found");
    }

    @Test
    void reportsAPageWithoutTextAsUnprocessable() {
        body = """
                {"query": {"pages": [{"pageid": 2, "title": "C++", "extract": ""}]}}
                """;

        assertFailure(HttpStatus.UNPROCESSABLE_ENTITY, "no_article_text");
    }

    @Test
    void reportsAnApiErrorAsBadGateway() {
        body = """
                {"error": {"code": "internal_api_error", "info": "boom"}}
                """;

        assertFailure(HttpStatus.BAD_GATEWAY, "wikipedia_unavailable");
    }

    @Test
    void reportsAServerErrorAsBadGateway() {
        status = 500;

        assertFailure(HttpStatus.BAD_GATEWAY, "wikipedia_unavailable");
    }

    @Test
    void doesNotFollowRedirects() {
        status = 302;
        location = "/elsewhere";

        assertFailure(HttpStatus.BAD_GATEWAY, "wikipedia_unavailable");
        assertThat(redirectTargetHits).hasValue(0);
    }

    @Test
    void refusesAResponseOverTheSizeLimit() {
        body = "{\"query\": {\"pages\": [{\"title\": \"C++\", \"extract\": \"" + "x".repeat(10_000) + "\"}]}}";

        assertThatThrownBy(() -> client(512).fetch(CPP)).isInstanceOfSatisfying(ApiException.class,
                e -> assertThat(e.code()).isEqualTo("wikipedia_unavailable"));
    }

    private void assertFailure(HttpStatus expectedStatus, String expectedCode) {
        assertThatThrownBy(() -> client(1024 * 1024).fetch(CPP)).isInstanceOfSatisfying(ApiException.class, e -> {
            assertThat(e.status()).isEqualTo(expectedStatus);
            assertThat(e.code()).isEqualTo(expectedCode);
        });
    }

    private WikipediaClient client(int maxResponseBytes) {
        var settings = new SummarizerProperties.Wikipedia(60_000, maxResponseBytes, Duration.ofSeconds(5), USER_AGENT);
        String api = "http://127.0.0.1:" + server.getAddress().getPort() + "/w/api.php";
        return new WikipediaClient(settings, JsonMapper.builder().build(), api);
    }
}
