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
// The client test creates a workspace in a Team; signup only provisions Personal.
const headerIdentity = { userId: "swift-test@example.com", email: "swift-test@example.com", name: "swift-test", source: "header" as const };
const userId = await store.resolveHeaderUser(headerIdentity);
if (!userId) throw new Error("Integration test user missing");
const identity = { ...headerIdentity, userId };
await store.ensureIdentityUser(identity);
await store.addAdminUser(identity.email);
await store.organizations.create(identity, { name: "Integration Team", slug: "integration-team", initialOwnerUserId: userId });
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
