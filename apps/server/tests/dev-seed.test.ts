import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { expect, it } from "vitest";
import { createApp } from "../src/app";
import { createNodeApplicationStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";
import { installDevelopmentSeed } from "../src/dev-seed";
import { uuidV7 } from "../src/id";
import { LocalObjectStorage } from "../src/storage/local";
import { MeetingSyncService } from "../src/sync/service";

it("seeds authenticated empty SQLite users atomically with UUIDv7 content and preserves edits on restart", async () => {
  const dir = mkdtempSync(join(tmpdir(), "dahlia-dev-seed-"));
  const path = join(dir, "db.sqlite");
  const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite",
    databaseUrl: `file:${path}`, baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1_048_576 };
  const store = createNodeApplicationStore(config);
  const originalProjector = store.ensureIdentityUser.bind(store);
  store.ensureIdentityUser = originalProjector;
  const sync = new MeetingSyncService(store.sync, new LocalObjectStorage(join(dir, "storage")));
  const headers = { "x-forwarded-email": "dev@example.com", "x-forwarded-user": uuidV7() };
  try {
    await store.migrate();
    for (const unsafe of [{ ...config, databaseType: "postgres" as const }, { ...config, baseUrl: "https://example.com" }]) {
      installDevelopmentSeed(unsafe, store, sync);
      expect(store.ensureIdentityUser === originalProjector).toBe(true);
    }
    installDevelopmentSeed(config, store, sync);
    const app = createApp({ config, authStore: store, syncService: sync });
    expect((await app.request("/api/v1/session")).status).toBe(401);
    const responses = await Promise.all(Array.from({ length: 3 }, async () => app.request("/api/v1/session", { headers })));
    expect(responses.map((response) => response.status)).toEqual([200, 200, 200]);
    const db = new DatabaseSync(path);
    try {
      const tables = [["workspaces", "workspace_id", 1], ["projects", "project_id", 1], ["meetings", "meeting_id", 3], ["summaries", "id", 3]] as const;
      for (const [table, column, count] of tables) {
        const rows = db.prepare(`SELECT ${column} AS id FROM ${table}`).all();
        expect(rows).toHaveLength(count);
        for (const row of rows) expect(row.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
      }
      expect(db.prepare("PRAGMA foreign_key_check").all()).toEqual([]);
      db.prepare("UPDATE meetings SET name = ?").run("編集済み");
      store.ensureIdentityUser = originalProjector;
      installDevelopmentSeed(config, store, sync);
      expect((await app.request("/api/v1/session", { headers })).status).toBe(200);
      expect(db.prepare("SELECT name FROM meetings").all()).toEqual(Array.from({ length: 3 }, () => ({ name: "編集済み" })));
    } finally { db.close(); }
  } finally {
    await store.close?.();
    rmSync(dir, { recursive: true, force: true });
  }
});
