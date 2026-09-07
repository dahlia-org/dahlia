import { drizzle } from "drizzle-orm/node-postgres";
import type { Pool } from "pg";
import { expect, it, vi } from "vitest";
import { createPostgresMeetingSyncStore } from "../src/sync/store";

it("decodes PostgreSQL project activity as UTC on a non-UTC host", async () => {
  vi.stubEnv("TZ", "Asia/Tokyo");
  try {
    const client = {
      async connect() { return this; },
      release() {},
      async query(input: string | { text: string }, parameters: unknown[] = []) {
        const text = typeof input === "string" ? input : input.text;
        if (text.includes("from pg_roles")) return { rows: [{ rolsuper: false, rolbypassrls: false }] };
        if (text.includes("from pg_class")) return { rows: [{ count: (parameters[0] as string[]).length }] };
        if (text.includes("max(")) return { rows: [["project", "2026-09-03 00:00:00"]] };
        return { rows: [] };
      },
    };
    const store = createPostgresMeetingSyncStore(drizzle({ client: client as unknown as Pool }));
    const result = await store.withIdentity({ userId: "owner", workspaceId: "personal:owner", source: "header" },
      (scoped) => scoped.searchProjectActivity("vault", {}));
    expect(result).toEqual([{ projectId: "project", updatedAt: "2026-09-03T00:00:00.000Z" }]);
  } finally { vi.unstubAllEnvs(); }
});
