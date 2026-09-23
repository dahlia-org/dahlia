import { ChatMemoryService, createMemoryGenerator } from "./agent/context-service";
import { ChatMemoryWorker } from "./agent/context-worker";
import { WorkspaceMemoryService } from "./memory/service";
import { MemoryWorker } from "./memory/node-worker";
import { createAudioSummaryMethod } from "./summary/audio";
import { createTranscriptSummaryMethod } from "./summary/transcript";
import { SummaryService } from "./summary/service";
import { SummaryWorker } from "./summary/node-worker";
import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { cimd } from "@better-auth/cimd";
import { fetchClientMetadataResource } from "@better-auth/cimd/node";
import type { Socket } from "node:net";

import { createApp } from "./app";
import { initializeDahliaAuth } from "./auth/better-auth";
import { createNodeApplicationStore } from "./auth/node-store";
import { DatabricksVolumeObjectStorage } from "./storage/databricks-volume";
import { LocalObjectStorage } from "./storage/local";
import { S3ObjectStorage } from "./storage/s3";
import { loadConfig } from "./config";
import { createNodeSearchTokenizer } from "./search/node-tokenizer";
import { createSearchEmbedder } from "./search/embedding";
import { SearchIndexer } from "./search/node-indexer";
import { transformScreenshot } from "./sync/node-screenshot-transformer";
import { MeetingSyncService } from "./sync/service";
import { createImageCaptioner } from "./image-analysis/captioner";
import { ImageAnalysisWorker } from "./image-analysis/node-worker";

const config = loadConfig(process.env);
const searchEmbedder = createSearchEmbedder(config);
const applicationStore = createNodeApplicationStore(config);
const searchIndexer = searchEmbedder && applicationStore.searchIndex
  ? new SearchIndexer(applicationStore.searchIndex, searchEmbedder)
  : undefined;
const auth = await initializeDahliaAuth(config, applicationStore, config.authProvider === "accounts" ? [{
      plugins: [cimd({ fetchClientMetadataResource, metadataProfile: "mcp-2026-07-28" })],
    }] : []);
const objectStorage = config.storageBackend === "databricks"
  ? new DatabricksVolumeObjectStorage(config.databricksWorkspace!, config.storageDatabricksVolumePath!)
  : config.storageBackend === "s3"
    ? new S3ObjectStorage(config.storageS3!)
    : config.storageBackend === "local"
      ? new LocalObjectStorage(config.storageLocalPath!)
      : undefined;
if (!objectStorage) throw new Error("R2 storage requires a Worker binding");
const searchTokenizer = createNodeSearchTokenizer();
const captioner = createImageCaptioner(config);
const syncService = new MeetingSyncService(applicationStore.sync, objectStorage, searchTokenizer,
  searchEmbedder, transformScreenshot,
  config.storageBackend === "databricks" ? config.storageDatabricksVolumePath : undefined,
  true, captioner?.model);
const workspaceMemory = config.hindsight && applicationStore.memory ? new WorkspaceMemoryService(config, applicationStore.memory, syncService, applicationStore.sync) : undefined;
const memoryWorker = workspaceMemory ? new MemoryWorker(workspaceMemory) : undefined;
const chatMemory = applicationStore.chatMemoryStore ? new ChatMemoryService(applicationStore.chatMemoryStore, syncService, createMemoryGenerator(config)) : undefined;
const chatMemoryWorker = chatMemory ? new ChatMemoryWorker(chatMemory) : undefined;
const development = process.argv.includes("--seed-dev");
if (development) {
  const { installDevelopmentSeed } = await import("./dev-seed");
  installDevelopmentSeed(config, applicationStore, syncService);
}
const imageAnalysis = captioner && applicationStore.imageAnalysis
  ? new ImageAnalysisWorker(applicationStore.imageAnalysis, captioner, applicationStore.sync, syncService)
  : undefined;

const summaryMethods = [createTranscriptSummaryMethod(config, applicationStore.sync, syncService),
  createAudioSummaryMethod(config, applicationStore.sync, syncService)].filter((method) => method !== undefined);
const summaryService = summaryMethods.length ? new SummaryService(applicationStore.sync, summaryMethods) : undefined;
const summaryWorker = summaryMethods.length ? new SummaryWorker(applicationStore.summaryJobs, summaryMethods, syncService) : undefined;
const app = createApp({
  summaryService,
  workspaceMemory,
  chatMemory,
  config,
  auth,
  mcpSupportsCimd: config.authProvider === "accounts",
  authStore: applicationStore,
  aiHistory: applicationStore.aiHistory,
  syncService,
  imageAnalysisEnabled: imageAnalysis !== undefined,
  objectStorage,
  searchTokenizer,
  searchEmbedder,
  screenshotTransformer: transformScreenshot,
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
  console.info(`Dahlia Server is listening on ${info.address}:${info.port}`);
});
memoryWorker?.start();
chatMemoryWorker?.start();
searchIndexer?.start();
imageAnalysis?.start();
summaryWorker?.start();
const sockets = new Set<Socket>();
server.on("connection", (socket: Socket) => {
  sockets.add(socket);
  socket.once("close", () => sockets.delete(socket));
});

let shuttingDown = false;
async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  const stoppedChatMemory = chatMemoryWorker?.stop();
  const stoppedMemory = memoryWorker?.stop();
  const stoppedSummary = summaryWorker?.stop();
  const stoppedIndexer = searchIndexer?.stop();
  const stoppedImageAnalysis = imageAnalysis?.stop();
  const closed = new Promise<void>((resolve) => server.close(() => resolve()));
  const deadline = setTimeout(() => {
    for (const socket of sockets) socket.destroy();
  }, 10_000);
  deadline.unref();
  await Promise.all([closed, stoppedIndexer, stoppedImageAnalysis, stoppedSummary, stoppedMemory, stoppedChatMemory]);
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
