package io.github.brunoborges.brewletagents.summarizer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.HttpStatus;

class WikipediaUrlTest {

    @ParameterizedTest
    @CsvSource(delimiter = '|', textBlock = """
            https://en.wikipedia.org/wiki/Java_(programming_language) | en.wikipedia.org | Java (programming language)
            https://en.m.wikipedia.org/wiki/Duke_(mascot)#History     | en.wikipedia.org | Duke (mascot)
            https://pt.wikipedia.org/wiki/S%C3%A3o_Paulo?useskin=vector | pt.wikipedia.org | São Paulo
            https://zh-yue.wikipedia.org/wiki/香港                     | zh-yue.wikipedia.org | 香港
            https://en.wikipedia.org/wiki/C++                         | en.wikipedia.org | C++
            HTTPS://EN.Wikipedia.ORG/wiki/Kubernetes                  | en.wikipedia.org | Kubernetes
            """)
    void acceptsArticleAddresses(String url, String host, String title) {
        WikipediaUrl parsed = WikipediaUrl.parse(url);

        assertThat(parsed.host()).isEqualTo(host);
        assertThat(parsed.title()).isEqualTo(title);
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {
            "   ",
            "not a url",
            "en.wikipedia.org/wiki/Java",
            "http://en.wikipedia.org/wiki/Java",
            "https://example.com/wiki/Java",
            "https://en.wikipedia.org.example.com/wiki/Java",
            "https://example.com/en.wikipedia.org/wiki/Java",
            "https://wikipedia.org/wiki/Java",
            "https://user:secret@en.wikipedia.org/wiki/Java",
            "https://en.wikipedia.org:8443/wiki/Java",
            "https://127.0.0.1/wiki/Java",
            "https://en.wikipedia.org/w/index.php?title=Java",
            "https://en.wikipedia.org/wiki/",
            "https://en.wikipedia.org/wiki/_",
            "https://en.wikipedia.org/wiki/Java%00Script",
    })
    void rejectsEverythingElse(String url) {
        assertThatThrownBy(() -> WikipediaUrl.parse(url)).isInstanceOfSatisfying(ApiException.class, e -> {
            assertThat(e.status()).isEqualTo(HttpStatus.BAD_REQUEST);
            assertThat(e.code()).isEqualTo("bad_request");
        });
    }

    @Test
    void rejectsAnUrlThatIsTooLong() {
        String url = "https://en.wikipedia.org/wiki/" + "a".repeat(3000);

        assertThatThrownBy(() -> WikipediaUrl.parse(url)).isInstanceOf(ApiException.class);
    }

    @Test
    void canonicalUrlIsTheEncodedAddressOfTheResolvedTitle() {
        WikipediaUrl parsed = WikipediaUrl.parse("https://pt.m.wikipedia.org/wiki/Sao_Paulo");

        assertThat(parsed.canonicalUrl("São Paulo")).isEqualTo("https://pt.wikipedia.org/wiki/S%C3%A3o_Paulo");
        assertThat(parsed.canonicalUrl("Java (programming language)"))
                .isEqualTo("https://pt.wikipedia.org/wiki/Java_(programming_language)");
    }
}
