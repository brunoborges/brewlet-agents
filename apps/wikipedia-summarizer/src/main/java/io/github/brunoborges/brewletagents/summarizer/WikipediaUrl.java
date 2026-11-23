package io.github.brunoborges.brewletagents.summarizer;

import java.net.URI;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.regex.Pattern;

import org.springframework.http.HttpStatus;
import org.springframework.web.util.UriUtils;

/**
 * An article on a Wikipedia language edition. The only accepted input is
 * {@code https://<language>.wikipedia.org/wiki/<title>}; the request that fetches the article is built from the
 * validated host and title, never from the string the caller sent.
 */
record WikipediaUrl(String host, String title) {

    // A language code such as en, pt, zh-yue or be-tarask. "m" is the mobile site, which serves the same articles.
    private static final Pattern HOST = Pattern.compile("[a-z]{2,12}(-[a-z0-9]{1,12})*(\\.m)?\\.wikipedia\\.org");
    private static final String ARTICLE_PATH = "/wiki/";
    private static final int MAX_URL_LENGTH = 2048;
    private static final int MAX_TITLE_LENGTH = 256;

    static WikipediaUrl parse(String raw) {
        if (raw == null || raw.isBlank()) {
            throw invalid("url is required");
        }
        String text = raw.strip();
        if (text.length() > MAX_URL_LENGTH) {
            throw invalid("url must be at most " + MAX_URL_LENGTH + " characters");
        }
        URI uri;
        try {
            uri = new URI(text);
        } catch (URISyntaxException e) {
            throw invalid("url is not a valid URL");
        }
        if (!"https".equalsIgnoreCase(uri.getScheme())) {
            throw invalid("only https:// Wikipedia URLs are supported");
        }
        if (uri.getUserInfo() != null || (uri.getPort() != -1 && uri.getPort() != 443)) {
            throw invalid("the URL must not have credentials or a port");
        }
        String host = uri.getHost() == null ? "" : uri.getHost().toLowerCase(Locale.ROOT);
        if (!HOST.matcher(host).matches()) {
            throw invalid("only <language>.wikipedia.org URLs are supported");
        }
        // getPath() is already percent-decoded and, unlike a query string, keeps '+' as it is: C++ is an article.
        String path = uri.getPath();
        if (path == null || !path.startsWith(ARTICLE_PATH)) {
            throw invalid("the URL path must be /wiki/<title>, like https://en.wikipedia.org/wiki/Java_(programming_language)");
        }
        String title = path.substring(ARTICLE_PATH.length()).replace('_', ' ').strip();
        if (title.isEmpty() || title.length() > MAX_TITLE_LENGTH || title.chars().anyMatch(Character::isISOControl)) {
            throw invalid("the URL does not contain a valid article title");
        }
        return new WikipediaUrl(host.replace(".m.wikipedia.org", ".wikipedia.org"), title);
    }

    /** The address of the article under its resolved title (the API follows redirects), as a public URL. */
    String canonicalUrl(String resolvedTitle) {
        return "https://" + host + ARTICLE_PATH
                + UriUtils.encodePath(resolvedTitle.replace(' ', '_'), StandardCharsets.UTF_8);
    }

    private static ApiException invalid(String message) {
        return new ApiException(HttpStatus.BAD_REQUEST, "bad_request", message);
    }
}
