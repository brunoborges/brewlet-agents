package io.github.brunoborges.brewletagents.summarizer;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

/**
 * Settings under {@code summarizer.*} in application.yml; every one can be overridden by an environment variable
 * such as {@code SUMMARIZER_WIKIPEDIA_MAX_ARTICLE_CHARS}.
 *
 * @param modelTimeout how long a request waits for the model
 */
@ConfigurationProperties("summarizer")
record SummarizerProperties(
        @DefaultValue("2m") Duration modelTimeout,
        @DefaultValue Wikipedia wikipedia) {

    /**
     * @param maxArticleChars article text beyond this many characters is not sent to the model
     * @param maxResponseBytes upper bound on what is read from one Wikipedia API response
     * @param timeout connect and response timeout of the Wikipedia API call
     * @param userAgent Wikimedia asks every client to identify itself with a descriptive User-Agent
     */
    record Wikipedia(
            @DefaultValue("60000") int maxArticleChars,
            @DefaultValue("8388608") int maxResponseBytes,
            @DefaultValue("10s") Duration timeout,
            @DefaultValue("wikipedia-summarizer/1.0 (https://github.com/brunoborges/brewlet-agents)") String userAgent) {

        Wikipedia {
            if (maxArticleChars < 1 || maxResponseBytes < 1) {
                throw new IllegalArgumentException(
                        "summarizer.wikipedia.max-article-chars and max-response-bytes must be positive");
            }
        }
    }
}
