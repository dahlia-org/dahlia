import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import type { Socket } from "node:net";

import { createApp } from "./app";
import { initializeDahliaAuth } from "./auth/better-auth";
import { createNodeApplicationStore } from "./auth/node-store";
import { loadConfig } from "./config";

const config = loadConfig(process.env);
const applicationStore = createNodeApplicationStore(config);
const auth = config.authProvider === "accounts" ? await initializeDahliaAuth(config, applicationStore) : undefined;

const app = createApp({
  config,
  auth,
  authStore: applicationStore,
});

app.use("*", serveStatic({ root: "./dist/client" }));
app.get("*", serveStatic({ path: "./dist/client/index.html" }));

const port = Number(process.env.DATABRICKS_APP_PORT ?? process.env.PORT ?? 3000);
const server = serve({
  fetch: app.fetch,
  hostname: "0.0.0.0",
  port,
}, (info) => {
  console.info(`Dahlia Server is listening on ${info.address}:${info.port}`);
});
const sockets = new Set<Socket>();
server.on("connection", (socket: Socket) => {
  sockets.add(socket);
  socket.once("close", () => sockets.delete(socket));
});

let shuttingDown = false;
async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  const closed = new Promise<void>((resolve) => server.close(() => resolve()));
  const deadline = setTimeout(() => {
    for (const socket of sockets) socket.destroy();
  }, 10_000);
  deadline.unref();
  await closed;
  clearTimeout(deadline);
  await applicationStore.close?.();
}

function beginShutdown(): void {
  void shutdown().catch(() => {
    console.error(JSON.stringify({ level: "error", event: "shutdown_failed" }));
    process.exitCode = 1;
  });
}

process.once("SIGINT", beginShutdown);
process.once("SIGTERM", beginShutdown);
