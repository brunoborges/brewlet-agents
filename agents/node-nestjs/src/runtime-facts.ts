import { CopilotTool } from "@copilot-sdk-integrations/nestjs";
import { Injectable } from "@nestjs/common";
import { dirname } from "node:path";
import { z } from "zod";
import { AppConfig } from "./config";
import { packageInfo } from "./package-info";
import { SidecarProbe } from "./sidecar-probe";

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
@Injectable()
export class RuntimeFacts {
  constructor(
    private readonly sidecar: SidecarProbe,
    private readonly config: AppConfig,
  ) {}

  async describe(): Promise<FactMap> {
    return {
      agent: {
        name: this.config.agentName,
        framework: this.framework(),
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
        integration: { ...packageInfo("@copilot-sdk-integrations/nestjs") },
        cli: await this.sidecar.describe(),
      },
      deployment: { ...this.config.deployment },
    };
  }

  @CopilotTool({
    name: "runtime_facts",
    description:
      "Verified facts about the environment this agent runs in: the Node.js runtime (version, home directory)," +
      " the application artifact (framework, code location), the Copilot SDK and integration versions, the" +
      " Copilot CLI sidecar (version, authentication) and the Kubernetes/Brewlet deployment (runtime image id," +
      " pod). Call it before answering any question about these.",
    input: TopicInput,
  })
  async runtimeFacts({ topic }: z.infer<typeof TopicInput>): Promise<string> {
    let facts = await this.describe();
    const wanted = (topic ?? "all").trim().toLowerCase();
    if (wanted !== "all" && Object.hasOwn(facts, wanted)) {
      facts = { [wanted]: facts[wanted] };
    }
    const lines: string[] = [];
    flatten("", facts, lines);
    return lines.map((line) => `${line}\n`).join("");
  }

  private framework(): FactMap {
    const { version } = packageInfo("@nestjs/core");
    return { name: "NestJS", version };
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
