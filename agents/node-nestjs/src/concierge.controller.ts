import {
  CopilotRuntimeUnavailableError,
  CopilotShuttingDownError,
  CopilotTimeoutError,
} from "@copilot-sdk-integrations/agent-core";
import { Body, Controller, Get, HttpCode, HttpException, HttpStatus, Logger, Post } from "@nestjs/common";
import { randomUUID } from "node:crypto";
import { ConciergeAgent } from "./concierge.agent";
import { RuntimeFacts } from "./runtime-facts";
import { SidecarError, SidecarProbe } from "./sidecar-probe";

const CONVERSATION_ID_PATTERN = "[A-Za-z0-9._:/-]{1,128}";
const CONVERSATION_ID = new RegExp(`^${CONVERSATION_ID_PATTERN}$`);
const MAX_QUESTION_LENGTH = 4000;

interface AskRequest {
  question?: unknown;
  conversationId?: unknown;
}

interface AskResponse {
  answer: string;
  conversationId: string;
}

/** The error body every agent in this repository returns: `{error, message}`. */
function problem(status: HttpStatus, error: string, message: string): HttpException {
  return new HttpException({ error, message }, status);
}

function describeDuration(ms: number): string {
  const [unit, size] = ms % 60_000 === 0 ? (["minute", 60_000] as const) : (["second", 1_000] as const);
  const count = ms / size;
  return Number.isInteger(count) ? `${count} ${unit}${count === 1 ? "" : "s"}` : `${ms} ms`;
}

/** The Runtime Concierge contract that every agent in this repository implements, whatever its language. */
@Controller()
export class ConciergeController {
  private readonly logger = new Logger(ConciergeController.name);

  constructor(
    private readonly agent: ConciergeAgent,
    private readonly sidecar: SidecarProbe,
    private readonly facts: RuntimeFacts,
  ) {}

  @Get("healthz")
  healthz(): { status: string } {
    return { status: "UP" };
  }

  @Get("readyz")
  async readyz(): Promise<{ status: string }> {
    if (await this.sidecar.isReachable()) return { status: "READY" };
    throw new HttpException({ status: "NOT_READY", reason: "copilot_cli_unreachable" }, HttpStatus.SERVICE_UNAVAILABLE);
  }

  @Get("runtime")
  runtime(): Promise<object> {
    return this.facts.describe();
  }

  @Post("ask")
  @HttpCode(HttpStatus.OK)
  async ask(@Body() body?: AskRequest): Promise<AskResponse> {
    const question = body?.question;
    if (typeof question !== "string" || question.trim() === "" || question.length > MAX_QUESTION_LENGTH) {
      throw problem(
        HttpStatus.BAD_REQUEST,
        "bad_request",
        `question is required and must be at most ${MAX_QUESTION_LENGTH} characters`,
      );
    }
    const conversationId = body?.conversationId ?? randomUUID();
    if (typeof conversationId !== "string" || !CONVERSATION_ID.test(conversationId)) {
      throw problem(HttpStatus.BAD_REQUEST, "bad_request", `conversationId must match ${CONVERSATION_ID_PATTERN}`);
    }

    await this.requireAuthenticatedSidecar();
    try {
      const answer = await this.agent.ask(conversationId, question);
      return { answer, conversationId };
    } catch (error) {
      throw this.agentFailure(error);
    }
  }

  private async requireAuthenticatedSidecar(): Promise<void> {
    try {
      if (await this.sidecar.isAuthenticated()) return;
    } catch (error) {
      if (error instanceof SidecarError) throw problem(HttpStatus.SERVICE_UNAVAILABLE, "copilot_unavailable", error.message);
      throw error;
    }
    throw problem(
      HttpStatus.SERVICE_UNAVAILABLE,
      "copilot_not_authenticated",
      "the Copilot CLI sidecar has no GitHub credentials; see docs/authentication.md",
    );
  }

  private agentFailure(error: unknown): HttpException {
    if (error instanceof CopilotTimeoutError) {
      return problem(
        HttpStatus.GATEWAY_TIMEOUT,
        "timeout",
        `the model did not answer within ${describeDuration(error.timeoutMs)}`,
      );
    }
    if (error instanceof CopilotRuntimeUnavailableError || error instanceof CopilotShuttingDownError) {
      return problem(HttpStatus.SERVICE_UNAVAILABLE, "copilot_unavailable", error.message);
    }
    this.logger.error(`the agent failed: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
    return problem(HttpStatus.BAD_GATEWAY, "agent_error", error instanceof Error ? error.message : String(error));
  }
}
