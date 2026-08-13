import { getConnInfo } from "@hono/node-server/conninfo";
import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import type { Context } from "hono";
import { createServer as createHttp2Server } from "node:http2";
import type { Socket } from "node:net";

import { createApp } from "./app";
import { initializeDahliaAuth } from "./auth/better-auth";
import { createNodeAuthStore } from "./auth/node-store";
import { loadConfig } from "./config";

const config = loadConfig(process.env);
const authStore = createNodeAuthStore(config);
const auth = config.authProvider === "accounts" ? await initializeDahliaAuth(config, authStore) : undefined;

const app = createApp({
  config,
  auth,
  authStore,
  remoteAddress: (context) => getConnInfo(context as Context).remote.address,
});

app.use("*", serveStatic({ root: "./dist/client" }));
app.get("*", serveStatic({ path: "./dist/client/index.html" }));

const port = Number(process.env.DATABRICKS_APP_PORT ?? process.env.PORT ?? 3000);
const server = serve({
  fetch: app.fetch,
  hostname: "0.0.0.0",
  port,
  ...(process.env.DATABRICKS_APP_PORT ? { createServer: createHttp2Server } : {}),
}, (info) => {
  console.info(`Dahlia Cloud is listening on ${info.address}:${info.port}`);
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
  await authStore?.close?.();
}

function beginShutdown(): void {
  void shutdown().catch(() => {
    console.error(JSON.stringify({ level: "error", event: "shutdown_failed" }));
    process.exitCode = 1;
  });
}

process.once("SIGINT", beginShutdown);
process.once("SIGTERM", beginShutdown);
