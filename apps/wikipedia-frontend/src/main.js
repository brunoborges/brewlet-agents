import { fileURLToPath } from 'node:url';

import { createApp } from './app.js';

// Where the summarizer listens. In the cluster this is the Service of the same namespace.
const agentUrl = process.env.AGENT_URL ?? 'http://localhost:8080';
const port = Number(process.env.PORT ?? 3000);

try {
  new URL(agentUrl);
} catch {
  console.error(`AGENT_URL is not a valid URL: ${agentUrl}`);
  process.exit(1);
}

const server = createApp({
  agentUrl,
  publicDir: fileURLToPath(new URL('../public', import.meta.url)),
});

server.listen(port, () => {
  console.log(`wikipedia-frontend listening on :${port}, summarizer at ${agentUrl}`);
});

// Let requests in flight finish when Kubernetes stops the Pod.
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    server.closeIdleConnections();
    setTimeout(() => process.exit(1), 10_000).unref();
  });
}
