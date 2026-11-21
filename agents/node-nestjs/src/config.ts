import { Injectable, Module } from "@nestjs/common";

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
@Injectable()
export class AppConfig {
  /** Where the Copilot CLI sidecar listens, and the shared secret the SDK presents to it. */
  readonly cliUrl = required("COPILOT_CLI_URL");
  readonly connectionToken = required("COPILOT_CONNECTION_TOKEN");

  readonly port = positiveInteger("PORT", 8080);
  readonly agentName = text("AGENT_NAME", "node-nestjs");

  /** How long a question may take before /ask answers 504. */
  readonly responseTimeoutMs = positiveInteger("COPILOT_RESPONSE_TIMEOUT_MS", 120_000);
  /** Conversations idle for longer than this are deleted from the sidecar. */
  readonly sessionMaxAgeMs = positiveInteger("COPILOT_SESSION_MAX_AGE_MS", 3_600_000);
  /** How long /readyz and /runtime wait for the sidecar. */
  readonly probeTimeoutMs = positiveInteger("COPILOT_PROBE_TIMEOUT_MS", 3_000);
  /** How long SIGTERM waits for in-flight questions before aborting them. */
  readonly shutdownGraceMs = positiveInteger("SHUTDOWN_GRACE_MS", 10_000);

  /** Downward API values reported by /runtime. */
  readonly deployment = {
    runtimeId: text("AGENT_RUNTIME_ID", "unknown"),
    pod: text("POD_NAME", text("HOSTNAME", "unknown")),
    namespace: text("POD_NAMESPACE", "unknown"),
    node: text("NODE_NAME", "unknown"),
  };
}

@Module({ providers: [AppConfig], exports: [AppConfig] })
export class AppConfigModule {}
