import type { Copilot } from "@copilot-sdk-integrations/agent-core";
import { InjectCopilot } from "@copilot-sdk-integrations/nestjs";
import type { CopilotClient } from "@microsoft/copilot-sdk";
import { Injectable } from "@nestjs/common";
import { AppConfig } from "./config";
import { TimeoutError, withTimeout } from "./with-timeout";

/** The calls the probe makes: the integration's `ClientLike` only types a part of the SDK client. */
type Sidecar = Pick<CopilotClient, "ping" | "getStatus" | "getAuthStatus">;

export class SidecarError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "SidecarError";
  }
}

/** Talks to the Copilot CLI sidecar through the SDK client that the integration already manages. */
@Injectable()
export class SidecarProbe {
  constructor(
    @InjectCopilot() private readonly copilot: Copilot,
    private readonly config: AppConfig,
  ) {}

  /** True when the sidecar answers a ping; the first call also connects the lazily started client. */
  async isReachable(): Promise<boolean> {
    try {
      await this.call((sidecar) => sidecar.ping("readyz"));
      return true;
    } catch (error) {
      if (error instanceof SidecarError) return false;
      throw error;
    }
  }

  /** Throws `SidecarError` when the sidecar cannot be reached. */
  async isAuthenticated(): Promise<boolean> {
    const auth = await this.call((sidecar) => sidecar.getAuthStatus());
    return auth.isAuthenticated;
  }

  /** Live facts about the sidecar; never throws, so /runtime works even when the sidecar is down. */
  async describe(): Promise<Record<string, string | number | boolean | null>> {
    const endpoint = this.config.cliUrl;
    try {
      const [status, auth] = await this.call((sidecar) => Promise.all([sidecar.getStatus(), sidecar.getAuthStatus()]));
      return {
        endpoint,
        attached: true,
        version: status.version,
        protocolVersion: status.protocolVersion,
        authenticated: auth.isAuthenticated,
        authType: auth.authType ?? null,
      };
    } catch (error) {
      if (!(error instanceof SidecarError)) throw error;
      return { endpoint, attached: false, error: error.message };
    }
  }

  private async call<T>(work: (sidecar: Sidecar) => Promise<T>): Promise<T> {
    const timeout = this.config.probeTimeoutMs;
    try {
      return await withTimeout(this.copilot.client().then((client) => work(client as unknown as Sidecar)), timeout);
    } catch (error) {
      if (error instanceof TimeoutError) {
        throw new SidecarError(`no answer from the Copilot CLI sidecar within ${timeout / 1000}s`, { cause: error });
      }
      const reason = error instanceof Error ? error.message : String(error);
      throw new SidecarError(`Copilot CLI sidecar is unreachable: ${reason}`, { cause: error });
    }
  }
}
