import { defineAgent, permissions, type CopilotAgentDefinition } from "@copilot-sdk-integrations/agent-core";
import { readFileSync } from "node:fs";
import type { RuntimeFacts } from "./runtime-facts.js";

// prompts/ ships next to dist/ in the artifact. The system prompt is a file, never inlined in code.
const instructions = readFileSync(new URL("../prompts/concierge.md", import.meta.url), "utf8");

/**
 * The agent sees only runtime_facts: `availableTools` allow-lists every tool source down to it (no shell,
 * files, network or GitHub tools), and the permissions approve that tool alone.
 */
export function conciergeAgent(facts: RuntimeFacts): CopilotAgentDefinition {
  return defineAgent({
    name: "concierge",
    instructions,
    tools: [facts.tool()],
    availableTools: ["custom:runtime_facts"],
    permissions: permissions.allowCustomTools(["runtime_facts"]),
  });
}
