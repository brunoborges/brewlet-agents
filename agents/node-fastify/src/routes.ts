import { randomUUID } from "node:crypto";
import type { FastifyPluginAsync } from "fastify";
import { agentFailure, Problem } from "./problem.js";
import type { RuntimeFacts } from "./runtime-facts.js";
import { SidecarError, type SidecarProbe } from "./sidecar-probe.js";

const CONVERSATION_ID_PATTERN = "[A-Za-z0-9._:/-]{1,128}";
const CONVERSATION_ID = new RegExp(`^${CONVERSATION_ID_PATTERN}$`);
const MAX_QUESTION_LENGTH = 4000;

export interface ConciergeRoutesOptions {
  sidecar: SidecarProbe;
  facts: RuntimeFacts;
}

function parseAsk(body: unknown): { question: string; conversationId: string } {
  const { question, conversationId = randomUUID() } = (typeof body === "object" && body !== null ? body : {}) as {
    question?: unknown;
    conversationId?: unknown;
  };
  if (typeof question !== "string" || question.trim() === "" || question.length > MAX_QUESTION_LENGTH) {
    throw new Problem(400, "bad_request", `question is required and must be at most ${MAX_QUESTION_LENGTH} characters`);
  }
  if (typeof conversationId !== "string" || !CONVERSATION_ID.test(conversationId)) {
    throw new Problem(400, "bad_request", `conversationId must match ${CONVERSATION_ID_PATTERN}`);
  }
  return { question, conversationId };
}

async function requireAuthenticatedSidecar(sidecar: SidecarProbe): Promise<void> {
  try {
    if (await sidecar.isAuthenticated()) return;
  } catch (error) {
    if (error instanceof SidecarError) throw new Problem(503, "copilot_unavailable", error.message);
    throw error;
  }
  throw new Problem(
    503,
    "copilot_not_authenticated",
    "the Copilot CLI sidecar has no GitHub credentials; see docs/authentication.md",
  );
}

/** The Runtime Concierge contract that every agent in this repository implements, whatever its language. */
export const conciergeRoutes: FastifyPluginAsync<ConciergeRoutesOptions> = async (app, { sidecar, facts }) => {
  app.get("/healthz", async () => ({ status: "UP" }));

  app.get("/readyz", async (_request, reply) => {
    if (await sidecar.isReachable()) return { status: "READY" };
    return reply.code(503).send({ status: "NOT_READY", reason: "copilot_cli_unreachable" });
  });

  app.get("/runtime", async () => facts.describe());

  app.post("/ask", async (request) => {
    const { question, conversationId } = parseAsk(request.body);
    await requireAuthenticatedSidecar(sidecar);
    try {
      // request.copilot binds the request's abort signal: the turn stops when the client disconnects.
      const answer = await request.copilot.agent("concierge").send({ prompt: question, conversationId });
      return { answer, conversationId };
    } catch (error) {
      throw agentFailure(error);
    }
  });
};
