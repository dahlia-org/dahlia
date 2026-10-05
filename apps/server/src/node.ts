import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { cimd } from "@better-auth/cimd";
import { fetchClientMetadataResource } from "@better-auth/cimd/node";
import type { Socket } from "node:net";
import { createApp } from "./app";
import { initializeDahliaAuth } from "./auth/better-auth";
import { loadConfig } from "./config";
import { transformScreenshot } from "./sync/node-screenshot-transformer";
import { createNodeServices } from "./jobs/node-services";
import { JobPool } from "./jobs/node-pool";
import { jobResources } from "./jobs/resources";
import { loadJobConfig } from "./jobs/model";
import { log, setLogSink } from "./otel/log";

const config = loadConfig(process.env);
const { applicationStore, searchEmbedder, objectStorage, searchTokenizer, captioner, syncService,
  workspaceMemory, personalMemory, chatMemory, summaryService, otel } = createNodeServices(config);
setLogSink(otel);
const auth = await initializeDahliaAuth(config, applicationStore, config.authProvider === "accounts" ? [{
  plugins: [cimd({ fetchClientMetadataResource, metadataProfile: "mcp-2026-07-28" })],
}] : []);
const development = process.argv.includes("--seed-dev");
if (development) {
  const { installDevelopmentSeed } = await import("./dev-seed");
  installDevelopmentSeed(config, applicationStore, syncService);
}
let failedWorker = false;
let onWorkerFailure = () => { failedWorker = true; };
const pool = new JobPool(new URL(import.meta.url.endsWith(".ts") ? "./job-worker.ts" : "./job-worker.js", import.meta.url),
  jobResources(config.jobs ?? loadJobConfig({})), () => onWorkerFailure());
try {
  await pool.start();
  if (failedWorker) throw new Error("job_worker_start_failed");
} catch (error) { await pool.stop(); await otel?.shutdown(); await applicationStore.close?.(); throw error; }
const app = createApp({
  summaryService,
  workspaceMemory,
  personalMemory,
  chatMemory,
  config,
  auth,
  mcpSupportsCimd: config.authProvider === "accounts",
  authStore: applicationStore,
  aiHistory: applicationStore.aiHistory,
  syncService,
  imageAnalysisEnabled: captioner !== undefined,
  objectStorage,
  searchTokenizer,
  searchEmbedder,
  screenshotTransformer: transformScreenshot,
  otel,
});

if (!development) {
  app.use("*", serveStatic({ root: "./dist/client" }));
  app.get("*", serveStatic({ path: "./dist/client/index.html" }));
}

const port = Number(process.env.DATABRICKS_APP_PORT ?? process.env.PORT ?? 3000);
const server = serve({
  fetch: app.fetch,
  hostname: "0.0.0.0",
  port,
}, (info) => {
  log("info", "server_listening", { address: info.address, port: info.port });
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
  const stoppedJobs = pool.stop();
  const closed = new Promise<void>((resolve) => server.close(() => resolve()));
  const deadline = setTimeout(() => {
    for (const socket of sockets) socket.destroy();
  }, 10_000);
  deadline.unref();
  await Promise.all([closed, stoppedJobs]);
  clearTimeout(deadline);
  await otel?.shutdown();
  await applicationStore.close?.();
  if (failedWorker) process.exitCode = 1;
}

function beginShutdown(): void {
  void shutdown().catch(() => {
    log("error", "shutdown_failed");
    process.exitCode = 1;
  });
}

onWorkerFailure = () => { failedWorker = true; beginShutdown(); };
process.once("SIGINT", beginShutdown);
process.once("SIGTERM", beginShutdown);
