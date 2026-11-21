package io.github.brunoborges.brewletagents.concierge;

import io.micronaut.context.annotation.ConfigurationProperties;

/** Where this process runs. Brewlet and the Pod spec provide the values as environment variables; see application.yml. */
@ConfigurationProperties("deployment")
public record Deployment(String agentName, String runtimeId, String pod, String namespace, String node) {
}
