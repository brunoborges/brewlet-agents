package io.github.brunoborges.brewletagents.summarizer;

import java.util.Set;

import io.micrometer.observation.Observation;
import io.micrometer.observation.ObservationPredicate;
import org.springframework.http.server.observation.ServerRequestObservationContext;
import org.springframework.stereotype.Component;

/**
 * Keeps the kubelet's liveness and readiness probes out of the traces and the request metrics. They
 * arrive every few seconds and would bury the summaries in the OpenTelemetry dashboard.
 */
@Component
class ProbeObservationFilter implements ObservationPredicate {

    private static final Set<String> PROBES = Set.of("/healthz", "/readyz");

    @Override
    public boolean test(String name, Observation.Context context) {
        return !(context instanceof ServerRequestObservationContext request
                && PROBES.contains(request.getCarrier().getRequestURI()));
    }
}
