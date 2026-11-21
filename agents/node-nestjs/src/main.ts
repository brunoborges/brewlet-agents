import "reflect-metadata";
import { Logger } from "@nestjs/common";
import { NestFactory } from "@nestjs/core";
import { AppModule } from "./app.module";
import { AppConfig } from "./config";

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);
  // On SIGTERM, drain the in-flight questions and stop the Copilot client before the process exits.
  app.enableShutdownHooks();
  const config = app.get(AppConfig);
  await app.listen(config.port, "0.0.0.0");
  new Logger("Concierge").log(
    `${config.agentName} listening on 0.0.0.0:${config.port} (started in ${Math.round(process.uptime() * 1000)} ms)`,
  );
}

bootstrap().catch((error: unknown) => {
  console.error("The agent failed to start:", error);
  process.exit(1);
});
