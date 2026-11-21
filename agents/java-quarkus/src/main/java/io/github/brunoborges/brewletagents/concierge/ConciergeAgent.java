package io.github.brunoborges.brewletagents.concierge;

import java.util.concurrent.CompletableFuture;

import com.microsoft.copilot.integrations.core.ConversationId;
import com.microsoft.copilot.integrations.core.CopilotAgent;
import com.microsoft.copilot.integrations.core.UserMessage;

/** The extension turns this interface into a CDI bean that sends each question to the Copilot CLI sidecar; settings live in application.properties. */
@CopilotAgent(name = "concierge", instructionsResource = "classpath:/prompts/concierge.md", toolRefs = "runtimeFacts")
public interface ConciergeAgent {

    CompletableFuture<String> ask(@ConversationId String conversationId, @UserMessage String question);
}
