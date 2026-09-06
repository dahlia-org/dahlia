import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { cimd } from "@better-auth/cimd";
import { fetchClientMetadataResource } from "@better-auth/cimd/node";
import type { Socket } from "node:net";

import { createApp } from "./app";
import { initializeDahliaAuth } from "./auth/better-auth";
import { createNodeApplicationStore } from "./auth/node-store";
import { DatabricksVolumeObjectStorage } from "./artifacts/databricks-volume";
import { LocalObjectStorage } from "./artifacts/local";
import { S3ObjectStorage } from "./artifacts/s3";
import { loadConfig } from "./config";
import { createNodeSearchTokenizer } from "./search/node-tokenizer";
import { createSearchEmbedder } from "./search/embedding";
import { SearchIndexer } from "./search/node-indexer";
import { transformScreenshot } from "./sync/node-screenshot-transformer";

const config = loadConfig(process.env);
const searchEmbedder = createSearchEmbedder(config);
const applicationStore = createNodeApplicationStore(config);
const searchIndexer = searchEmbedder && applicationStore.searchIndex
  ? new SearchIndexer(applicationStore.searchIndex, searchEmbedder)
  : undefined;
const auth = config.authProvider === "accounts"
  ? await initializeDahliaAuth(config, applicationStore, [{
      plugins: [cimd({ fetchClientMetadataResource, metadataProfile: "mcp-2026-07-28" })],
    }])
  : undefined;
const artifactStorage = config.storageBackend === "databricks"
  ? new DatabricksVolumeObjectStorage(config.databricksWorkspace!, config.storageDatabricksVolumePath!)
  : config.storageBackend === "s3"
    ? new S3ObjectStorage(config.storageS3!)
    : config.storageBackend === "local"
      ? new LocalObjectStorage(config.storageLocalPath!)
      : undefined;
if (!artifactStorage) throw new Error("R2 storage requires a Worker binding");

const app = createApp({
  config,
  auth,
  authStore: applicationStore,
  artifactStorage,
  searchTokenizer: createNodeSearchTokenizer(),
  searchEmbedder,
  screenshotTransformer: transformScreenshot,
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
searchIndexer?.start();
const sockets = new Set<Socket>();
server.on("connection", (socket: Socket) => {
  sockets.add(socket);
  socket.once("close", () => sockets.delete(socket));
});

let shuttingDown = false;
async function shutdown(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  const stoppedIndexer = searchIndexer?.stop();
  const closed = new Promise<void>((resolve) => server.close(() => resolve()));
  const deadline = setTimeout(() => {
    for (const socket of sockets) socket.destroy();
  }, 10_000);
  deadline.unref();
  await Promise.all([closed, stoppedIndexer]);
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
