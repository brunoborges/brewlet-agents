import { defineCopilotTool } from "@copilot-sdk-integrations/agent-core";
import { dirname } from "node:path";
import { z } from "zod";
import type { AppConfig } from "./config.js";
import { packageInfo } from "./package-info.js";
import type { SidecarProbe } from "./sidecar-probe.js";

export type FactValue = string | number | boolean | null | FactMap;
export interface FactMap {
  [key: string]: FactValue;
}

const TopicInput = z.object({
  topic: z.string().optional().describe("Which part to return: all, language, agent, copilot or deployment"),
});

/**
 * The facts the Runtime Concierge reports, both over GET /runtime and to the model through the
 * runtime_facts tool. Everything is read from the live process, so the answer shows what Brewlet
 * actually launched.
 */
export class RuntimeFacts {
  constructor(
    private readonly sidecar: SidecarProbe,
    private readonly config: AppConfig,
  ) {}

  async describe(): Promise<FactMap> {
    return {
      agent: {
        name: this.config.agentName,
        framework: { name: "Fastify", version: packageInfo("fastify").version },
        location: process.argv[1] ?? "unknown",
      },
      language: {
        name: "node",
        version: process.versions.node,
        vendor: "Node.js",
        // <home>/bin/node: the runtime image, not the application.
        home: dirname(dirname(process.execPath)),
      },
      copilot: {
        sdk: { ...packageInfo("@microsoft/copilot-sdk") },
        integration: { ...packageInfo("@copilot-sdk-integrations/fastify") },
        cli: await this.sidecar.describe(),
      },
      deployment: { ...this.config.deployment },
    };
  }

  /** The tool the model calls; it returns the same facts as GET /runtime, as `key: value` lines. */
  tool() {
    return defineCopilotTool({
      name: "runtime_facts",
      description:
        "Verified facts about the environment this agent runs in: the Node.js runtime (version, home directory)," +
        " the application artifact (framework, code location), the Copilot SDK and integration versions, the" +
        " Copilot CLI sidecar (version, authentication) and the Kubernetes/Brewlet deployment (runtime image id," +
        " pod). Call it before answering any question about these.",
      input: TopicInput,
      execute: async ({ topic }: z.infer<typeof TopicInput>) => {
        let facts = await this.describe();
        const wanted = (topic ?? "all").trim().toLowerCase();
        if (wanted !== "all" && Object.hasOwn(facts, wanted)) {
          facts = { [wanted]: facts[wanted] };
        }
        const lines: string[] = [];
        flatten("", facts, lines);
        return lines.map((line) => `${line}\n`).join("");
      },
    });
  }
}

function flatten(prefix: string, values: FactMap, lines: string[]): void {
  for (const [key, value] of Object.entries(values)) {
    const name = prefix === "" ? key : `${prefix}.${key}`;
    if (value !== null && typeof value === "object") {
      flatten(name, value, lines);
    } else {
      lines.push(`${name}: ${value}`);
    }
  }
}
