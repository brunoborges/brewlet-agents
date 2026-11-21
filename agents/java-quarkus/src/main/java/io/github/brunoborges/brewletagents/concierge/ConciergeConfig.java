package io.github.brunoborges.brewletagents.concierge;

import io.smallrye.config.ConfigMapping;

/**
 * What the Pod spec tells the process about its deployment. The values come from the concierge.* keys in
 * application.properties, which read the environment variables the Pod sets.
 */
@ConfigMapping(prefix = "concierge")
public interface ConciergeConfig {

    String agentName();

    String runtimeId();

    String pod();

    String namespace();

    String node();
}
