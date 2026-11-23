package io.github.brunoborges.brewletagents.summarizer;

/** Where the text of an article comes from. */
interface ArticleSource {

    /** The plain-text article, or an {@link ApiException} saying why it cannot be had. */
    Article fetch(WikipediaUrl url);

    /** @param title the article's title after redirects and normalization */
    record Article(String title, String text) {
    }
}
