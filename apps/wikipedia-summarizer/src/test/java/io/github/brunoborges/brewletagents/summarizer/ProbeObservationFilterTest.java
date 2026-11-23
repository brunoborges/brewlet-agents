package io.github.brunoborges.brewletagents.summarizer;

import static org.assertj.core.api.Assertions.assertThat;

import io.micrometer.observation.Observation;
import org.junit.jupiter.api.Test;
import org.springframework.http.server.observation.ServerRequestObservationContext;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

class ProbeObservationFilterTest {

    private final ProbeObservationFilter filter = new ProbeObservationFilter();

    @Test
    void skipsTheKubeletProbesAndNothingElse() {
        assertThat(filter.test("http.server.requests", request("GET", "/healthz"))).isFalse();
        assertThat(filter.test("http.server.requests", request("GET", "/readyz"))).isFalse();
        assertThat(filter.test("http.server.requests", request("POST", "/api/summaries"))).isTrue();
        assertThat(filter.test("summarizer.fetch", new Observation.Context())).isTrue();
    }

    private static ServerRequestObservationContext request(String method, String path) {
        return new ServerRequestObservationContext(new MockHttpServletRequest(method, path),
                new MockHttpServletResponse());
    }
}
