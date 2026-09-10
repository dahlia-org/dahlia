import { drizzle } from "drizzle-orm/node-postgres";
import type { Pool } from "pg";
import { expect, it, vi } from "vitest";
import { createPostgresMeetingSyncStore } from "../src/sync/store";
import { DEFAULT_SEARCH_SETTINGS, SEARCH_FIELDS } from "../src/search/settings-model";

it("disables Lakebase top-K scans before weighted ranking and reads settings once per identity transaction", async () => {
  const queries: Array<{ text: string; parameters: unknown[] }> = [];
  const client = {
    async connect() { return this; },
    release() {},
    async query(input: string | { text: string }, parameters: unknown[] = []) {
      const text = typeof input === "string" ? input : input.text;
      queries.push({ text, parameters });
      if (text.includes("from pg_roles")) return { rows: [{ rolsuper: false, rolbypassrls: false }] };
      if (text.includes("from pg_class")) return { rows: [{ count: (parameters[0] as string[]).length }] };
      if (text.includes('from "app"."server_settings"')) return { rows: [[{ ...DEFAULT_SEARCH_SETTINGS, title: 9 }]] };
      return { rows: [] };
    },
  };
  const store = createPostgresMeetingSyncStore(drizzle({ client: client as unknown as Pool }), "lakebase");
  await store.withIdentity({ userId: "owner", workspaceId: "personal:owner", source: "header" }, async (scoped) => {
    const query = { text: "alpha beta", tokens: ["alpha", "beta"] };
    await scoped.listMeetings("vault", query, 100);
    await scoped.listScreenshots("vault", undefined, query, 100);
  });
  expect(queries.filter(({ text }) => text.includes('from "app"."server_settings"'))).toHaveLength(1);
  const disableIndex = queries.findIndex(({ text }) => text.includes("set_config('lakebase_bm25.enable_scan', 'false', true)"));
  const rankIndex = queries.findIndex(({ text }) => text.includes("to_bm25query"));
  expect(disableIndex).toBeGreaterThan(-1);
  expect(rankIndex).toBeGreaterThan(disableIndex);
  expect(queries[rankIndex]!.parameters).toContain(9);
  for (const field of SEARCH_FIELDS) expect(queries[rankIndex]!.parameters).toContain(`app.search_documents_${field}_bm25`);
  expect(queries[rankIndex]!.text).toContain(" @@ plainto_tsquery");
});

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
