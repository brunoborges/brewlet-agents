import { CopilotModule } from "@copilot-sdk-integrations/nestjs";
import { RuntimeConnection } from "@microsoft/copilot-sdk";
import { Module } from "@nestjs/common";
import { ConciergeAgent } from "./concierge.agent";
import { ConciergeController } from "./concierge.controller";
import { AppConfig, AppConfigModule } from "./config";
import { RuntimeFacts } from "./runtime-facts";
import { SidecarProbe } from "./sidecar-probe";

@Module({
  imports: [
    AppConfigModule,
    CopilotModule.forRootAsync({
      imports: [AppConfigModule],
      inject: [AppConfig],
      useFactory: (config: AppConfig) => ({
        // The Copilot CLI runs in the sidecar container of the same Pod; the client connects on first use.
        cliUrl: config.cliUrl,
        startup: "lazy",
        responseTimeout: config.responseTimeoutMs,
        sessionCleanup: { maxAge: config.sessionMaxAgeMs },
        shutdownGracePeriod: config.shutdownGraceMs,
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
        // The controller maps failures to the contract's error bodies; the default filter's differ.
        exceptionFilter: false,
      }),
    }),
    CopilotModule.forFeature([ConciergeAgent]),
  ],
  controllers: [ConciergeController],
  providers: [RuntimeFacts, SidecarProbe],
})
export class AppModule {}
