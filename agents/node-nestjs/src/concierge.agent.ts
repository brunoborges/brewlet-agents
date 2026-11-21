import { permissions } from "@copilot-sdk-integrations/agent-core";
import { ConversationId, CopilotAgent, implementedByCopilot, Message, UserMessage } from "@copilot-sdk-integrations/nestjs";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { RuntimeFacts } from "./runtime-facts";

// prompts/ ships next to dist/ in the artifact. The system prompt is a file, never inlined in code.
const instructions = readFileSync(join(__dirname, "..", "prompts", "concierge.md"), "utf8");

/**
 * The module implements the stub: each question goes to the Copilot CLI sidecar. The agent sees only
 * runtime_facts: no built-in tools (no shell, files or network), and permissions approve that tool alone.
 */
@CopilotAgent({
  name: "concierge",
  instructions,
  tools: [RuntimeFacts],
  availableTools: ["custom:runtime_facts"],
  permissions: permissions.allowCustomTools(["runtime_facts"]),
})
export abstract class ConciergeAgent {
  @UserMessage()
  ask(@ConversationId() conversationId: string, @Message() question: string): Promise<string> {
    return implementedByCopilot();
  }
}
