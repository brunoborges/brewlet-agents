import {
  CLIENT_CLOSED_REQUEST,
  CopilotAbortedError,
  CopilotRuntimeUnavailableError,
  CopilotShuttingDownError,
  CopilotTimeoutError,
} from "@copilot-sdk-integrations/agent-core";
import type { FastifyReply, FastifyRequest } from "fastify";

/** A failure with the HTTP status and the `{error, message}` body that the contract specifies. */
export class Problem extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    options?: { cause?: unknown },
  ) {
    super(message, options);
    this.name = "Problem";
  }
}

function describeDuration(ms: number): string {
  const [unit, size] = ms % 60_000 === 0 ? (["minute", 60_000] as const) : (["second", 1_000] as const);
  const count = ms / size;
  return Number.isInteger(count) ? `${count} ${unit}${count === 1 ? "" : "s"}` : `${ms} ms`;
}

/** Maps what the integration throws for a question to the contract's statuses: 504, 503, or 502 for the rest. */
export function agentFailure(error: unknown): Problem {
  if (error instanceof CopilotTimeoutError) {
    return new Problem(504, "timeout", `the model did not answer within ${describeDuration(error.timeoutMs)}`, { cause: error });
  }
  if (error instanceof CopilotRuntimeUnavailableError || error instanceof CopilotShuttingDownError) {
    return new Problem(503, "copilot_unavailable", error.message, { cause: error });
  }
  // The integration aborts a turn when the client disconnects before the answer is ready.
  if (error instanceof CopilotAbortedError) {
    return new Problem(CLIENT_CLOSED_REQUEST, "client_closed_request", error.message, { cause: error });
  }
  return new Problem(502, "agent_error", error instanceof Error ? error.message : String(error), { cause: error });
}

function clientErrorStatus(error: Error): number | undefined {
  const status = (error as { statusCode?: unknown }).statusCode;
  return typeof status === "number" && status >= 400 && status < 500 ? status : undefined;
}

/**
 * The root error handler: every error leaves as `{error, message}`. Fastify's own client errors
 * (malformed JSON, a body that is too large) are `bad_request`; anything unexpected is a 500.
 */
export function errorHandler(error: Error, request: FastifyRequest, reply: FastifyReply): FastifyReply {
  const status = clientErrorStatus(error);
  const problem =
    error instanceof Problem
      ? error
      : status !== undefined
        ? new Problem(status, "bad_request", error.message, { cause: error })
        : new Problem(500, "internal_error", "internal server error", { cause: error });
  if (problem.status >= 500) request.log.error({ err: problem.cause ?? problem }, problem.message);
  return reply.code(problem.status).send({ error: problem.code, message: problem.message });
}
