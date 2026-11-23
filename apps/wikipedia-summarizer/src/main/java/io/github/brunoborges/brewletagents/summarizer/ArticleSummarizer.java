package io.github.brunoborges.brewletagents.summarizer;

import java.util.concurrent.CompletableFuture;

import com.microsoft.copilot.integrations.core.ConversationId;
import com.microsoft.copilot.integrations.core.CopilotAgent;
import com.microsoft.copilot.integrations.core.UserMessage;

/** The model side of the app: the starter generates the implementation, which talks to the Copilot CLI sidecar. */
@CopilotAgent(name = "summarizer", instructionsResource = "classpath:/prompts/summarizer.md")
public interface ArticleSummarizer {

    CompletableFuture<String> summarize(@ConversationId String conversationId, @UserMessage String request);
}
