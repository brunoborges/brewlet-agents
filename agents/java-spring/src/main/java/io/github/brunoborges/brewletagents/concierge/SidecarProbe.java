package io.github.brunoborges.brewletagents.concierge;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import com.microsoft.copilot.CopilotClient;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Talks to the Copilot CLI sidecar through the SDK client that the starter already configured. */
@Component
public class SidecarProbe {

    private static final long TIMEOUT_SECONDS = 3;

    private final CopilotClient client;
    private final String endpoint;

    public SidecarProbe(CopilotClient client, @Value("${copilot.cli-url}") String endpoint) {
        this.client = client;
        this.endpoint = endpoint;
    }

    /** True when the sidecar answers a ping; the first call also connects the lazily started client. */
    public boolean isReachable() {
        try {
            await(client.ping("readyz"));
            return true;
        } catch (SidecarException e) {
            return false;
        }
    }

    public boolean isAuthenticated() {
        return await(client.getAuthStatus()).isAuthenticated();
    }

    /** Live facts about the sidecar; never throws, so /runtime works even when the sidecar is down. */
    public Map<String, Object> describe() {
        Map<String, Object> cli = new LinkedHashMap<>();
        cli.put("endpoint", endpoint);
        try {
            var status = await(client.getStatus());
            var auth = await(client.getAuthStatus());
            cli.put("attached", true);
            cli.put("version", status.getVersion());
            cli.put("protocolVersion", status.getProtocolVersion());
            cli.put("authenticated", auth.isAuthenticated());
            cli.put("authType", auth.getAuthType());
        } catch (SidecarException e) {
            cli.put("attached", false);
            cli.put("error", e.getMessage());
        }
        return cli;
    }

    private static <T> T await(CompletableFuture<T> future) {
        try {
            return future.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new SidecarException("interrupted", e);
        } catch (TimeoutException e) {
            future.cancel(true);
            throw new SidecarException("no answer from the Copilot CLI sidecar within " + TIMEOUT_SECONDS + "s", e);
        } catch (ExecutionException e) {
            throw new SidecarException("Copilot CLI sidecar is unreachable: " + e.getCause(), e);
        }
    }

    static final class SidecarException extends RuntimeException {
        SidecarException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
