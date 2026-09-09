// Local-only server for the Swift generated-client integration test. Uses disposable SQLite/storage.
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serve } from "@hono/node-server";
import { createApp } from "../src/app";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { LocalObjectStorage } from "../src/storage/local";

const destination = process.argv[2] ?? "";
if (!destination) throw new Error("Pass the temporary endpoint file path");
const directory = await mkdtemp(join(tmpdir(), "dahlia-swift-api-"));
const config = { authProvider: "header" as const, authHeader: "X-Forwarded-Email", databaseType: "sqlite" as const,
  databaseUrl: `file:${join(directory, "server.sqlite")}`, baseUrl: "http://127.0.0.1", oauthRedirectUris: [], maxRequestBytes: 8 * 1024 * 1024,
  storageBackend: "databricks" as const, storageDatabricksVolumePath: "/Volumes/test/app/files" };
const store = createNodeApplicationStore(config);
await store.migrate();
const app = createApp({ config, authStore: store, objectStorage: new LocalObjectStorage(join(directory, "objects")) });
const server = serve({ fetch: app.fetch, hostname: "127.0.0.1", port: 0 }, (address) => {
  void writeFile(destination, `http://127.0.0.1:${address.port}`).catch((error: unknown) => { console.error(error); process.exitCode = 1; });
});
async function close() {
  await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  await store.close?.();
  await rm(directory, { recursive: true, force: true });
  await rm(destination, { force: true });
}
for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, () => { void close().catch((error: unknown) => { console.error(error); process.exitCode = 1; }); });
