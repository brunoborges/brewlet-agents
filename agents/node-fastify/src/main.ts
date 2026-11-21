import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";

// All interfaces: the kubelet probes and the port-forward reach the agent through the Pod IP.
const LISTEN_HOST = "0.0.0.0";

async function main(): Promise<void> {
  const config = loadConfig();
  const app = await buildApp(config);

  // On SIGTERM, app.close() drains the in-flight questions and stops the Copilot client, then the process exits.
  let closing = false;
  const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
    if (closing) return;
    closing = true;
    app.log.info({ signal }, "shutting down");
    try {
      await app.close();
      process.exit(0);
    } catch (error) {
      app.log.error(error, "shutdown failed");
      process.exit(1);
    }
  };
  process.on("SIGTERM", (signal) => void shutdown(signal));
  process.on("SIGINT", (signal) => void shutdown(signal));

  await app.listen({ host: LISTEN_HOST, port: config.port });
  app.log.info(
    `${config.agentName} listening on ${LISTEN_HOST}:${config.port} (started in ${Math.round(process.uptime() * 1000)} ms)`,
  );
}

main().catch((error: unknown) => {
  console.error("The agent failed to start:", error);
  process.exit(1);
});
