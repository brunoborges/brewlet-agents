import { copilotPlugin } from "@copilot-sdk-integrations/fastify";
import { RuntimeConnection } from "@microsoft/copilot-sdk";
import Fastify, { LogController, type FastifyInstance } from "fastify";
import { conciergeAgent } from "./concierge.js";
import type { AppConfig } from "./config.js";
import { errorHandler } from "./problem.js";
import { conciergeRoutes } from "./routes.js";
import { RuntimeFacts } from "./runtime-facts.js";
import { SidecarProbe } from "./sidecar-probe.js";

// Kubernetes probes the agent every few seconds; their request logs would drown the questions'.
const PROBE_PATHS = new Set(["/healthz", "/readyz"]);

export async function buildApp(config: AppConfig): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: config.logLevel },
    logController: new LogController({ disableRequestLogging: (request) => PROBE_PATHS.has(request.url) }),
  });

  await app.register(copilotPlugin, {
    client: {
      // The Copilot CLI runs in the sidecar container of the same Pod; the client connects on first use.
      cliUrl: config.cliUrl,
      responseTimeout: config.responseTimeoutMs,
      // The integration builds a TCP runtime connection from cliUrl but has no option for the
      // connection token, so it is added to that connection here.
      configureClient: (options) =>
        options.runtime?.kind === "tcp"
          ? {
              ...options,
              runtime: RuntimeConnection.forTcp(options.runtime.host, options.runtime.port, {
                connectionToken: config.connectionToken,
              }),
            }
          : options,
    },
    startup: "lazy",
    sessionCleanup: { maxAge: config.sessionMaxAgeMs },
    shutdownGracePeriod: config.shutdownGraceMs,
    // errorHandler below answers with the contract's bodies; the plugin's default ones differ.
    errorHandler: false,
  });

  // The tool reads the sidecar through the client the plugin manages, so the agent is registered
  // once the plugin has created it.
  const sidecar = new SidecarProbe(app.copilot, config);
  const facts = new RuntimeFacts(sidecar, config);
  app.copilot.registerAgent(conciergeAgent(facts));

  app.setErrorHandler(errorHandler);
  await app.register(conciergeRoutes, { sidecar, facts });
  return app;
}
