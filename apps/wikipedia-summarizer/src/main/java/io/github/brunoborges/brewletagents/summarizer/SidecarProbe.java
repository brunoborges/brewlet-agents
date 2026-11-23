package io.github.brunoborges.brewletagents.summarizer;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import com.microsoft.copilot.CopilotClient;
import org.springframework.stereotype.Component;

/** Talks to the Copilot CLI sidecar through the SDK client that the starter already configured. */
@Component
class SidecarProbe {

    private static final long TIMEOUT_SECONDS = 3;

    private final CopilotClient client;

    SidecarProbe(CopilotClient client) {
        this.client = client;
    }

    /** True when the sidecar answers a ping; the first call also connects the lazily started client. */
    boolean isReachable() {
        try {
            await(client.ping("readyz"));
            return true;
        } catch (SidecarException e) {
            return false;
        }
    }

    boolean isAuthenticated() {
        return await(client.getAuthStatus()).isAuthenticated();
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
