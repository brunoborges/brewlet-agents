export interface AppConfig {
  /** Where the Copilot CLI sidecar listens, and the shared secret the SDK presents to it. */
  readonly cliUrl: string;
  readonly connectionToken: string;
  readonly port: number;
  readonly agentName: string;
  readonly logLevel: string;
  /** How long a question may take before /ask answers 504. */
  readonly responseTimeoutMs: number;
  /** Conversations idle for longer than this are deleted from the sidecar. */
  readonly sessionMaxAgeMs: number;
  /** How long /readyz and /runtime wait for the sidecar. */
  readonly probeTimeoutMs: number;
  /** How long SIGTERM waits for in-flight questions before aborting them. */
  readonly shutdownGraceMs: number;
  /** Downward API values reported by /runtime. */
  readonly deployment: { runtimeId: string; pod: string; namespace: string; node: string };
}

function required(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.trim() === "") {
    throw new Error(`${name} must be set: the Pod spec provides it, and there is deliberately no default`);
  }
  return value;
}

function text(name: string, fallback: string): string {
  const value = process.env[name];
  return value === undefined || value.trim() === "" ? fallback : value.trim();
}

function positiveInteger(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) throw new Error(`${name} must be a positive integer`);
  return value;
}

/** Every setting comes from the environment; the defaults below are the only values kept in code. */
export function loadConfig(): AppConfig {
  return {
    cliUrl: required("COPILOT_CLI_URL"),
    connectionToken: required("COPILOT_CONNECTION_TOKEN"),
    port: positiveInteger("PORT", 8080),
    agentName: text("AGENT_NAME", "node-fastify"),
    logLevel: text("LOG_LEVEL", "info"),
    responseTimeoutMs: positiveInteger("COPILOT_RESPONSE_TIMEOUT_MS", 120_000),
    sessionMaxAgeMs: positiveInteger("COPILOT_SESSION_MAX_AGE_MS", 3_600_000),
    probeTimeoutMs: positiveInteger("COPILOT_PROBE_TIMEOUT_MS", 3_000),
    shutdownGraceMs: positiveInteger("SHUTDOWN_GRACE_MS", 10_000),
    deployment: {
      runtimeId: text("AGENT_RUNTIME_ID", "unknown"),
      pod: text("POD_NAME", text("HOSTNAME", "unknown")),
      namespace: text("POD_NAMESPACE", "unknown"),
      node: text("NODE_NAME", "unknown"),
    },
  };
}
