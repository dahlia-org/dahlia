import { describe, expect, it, vi } from "vitest";

import { globSync, readFileSync } from "node:fs";

import type { AppConfig } from "../src/config";
import { createD1ApplicationStore } from "../src/auth/store";
import { ensureSearchIndexes, postgresMigrationConfigs, readPostgresMigrations } from "../src/db/client";
import { createPostgresPool } from "../src/db/postgres";
import { postgresMigrations, serverMigrationManifest } from "../src/migrations";

describe("PostgreSQL migrations", () => {
  it("fails D1 sync closed until writes use atomic D1 batches", async () => {
    const store = createD1ApplicationStore({ prepare: vi.fn() });
    expect(await store.sync.isAvailable()).toBe(false);
  });

  it("migrates generated auth tables before application tables in every authentication mode", () => {
    expect(postgresMigrations(serverMigrationManifest).map(({ id }) => id))
      .toEqual(["auth", "server"]);
  });

  it("tracks each extension directory by stable ledger ID", () => {
    expect(postgresMigrationConfigs([
      { id: "server", path: "server" },
      { id: "billing", path: "billing" },
      { id: "analytics", path: "analytics" },
    ])).toEqual([
      { migrationsFolder: "server", migrationsSchema: "drizzle", migrationsTable: "__dahlia_server_migrations" },
      { migrationsFolder: "billing", migrationsSchema: "drizzle", migrationsTable: "__dahlia_billing_migrations" },
      { migrationsFolder: "analytics", migrationsSchema: "drizzle", migrationsTable: "__dahlia_analytics_migrations" },
    ]);
    expect(postgresMigrationConfigs([
      { id: "server", path: "server" },
      { id: "analytics", path: "analytics" },
      { id: "billing", path: "billing" },
    ])[2]).toEqual({
      migrationsFolder: "billing",
      migrationsSchema: "drizzle",
      migrationsTable: "__dahlia_billing_migrations",
    });
  });

  it("uses the application schemas in dependency order", async () => {
    const pool = createPostgresPool("postgresql://dahlia@127.0.0.1:5432/dahlia", 1);
    expect(pool.options.options).toBe("-c search_path=core,content,auth");
    await pool.end();
  });

  it.each([
    ["lakebase", "lakebase_vector CASCADE", "lakebase_ann"],
    ["postgres", "vector", "hnsw"],
  ] as const)("uses the native %s vector extension and index", async (databaseType, extension, method) => {
    const query = vi.fn(async (statement: string) => statement.startsWith("select quote_literal")
      ? { rows: [{ value: "'model'" }] }
      : { rows: [] });
    await ensureSearchIndexes({ query } as never, {
      databaseType,
      searchEmbedding: { model: "model", dimensions: 32 },
    } as AppConfig);
    const statements = query.mock.calls.map(([statement]) => statement);
    expect(statements).toContain(`CREATE EXTENSION IF NOT EXISTS ${extension}`);
    const vectorType = databaseType === "lakebase" ? "vector(32)" : "public.vector(32)";
    const operatorClass = databaseType === "lakebase" ? "vector_cosine_ops" : "public.vector_cosine_ops";
    expect(statements.some((statement) => statement.includes(`USING ${method}`)
      && statement.includes(`embedding::${vectorType}`)
      && statement.includes(operatorClass))).toBe(true);
    if (databaseType === "lakebase") {
      expect(statements).toContain("CREATE EXTENSION IF NOT EXISTS lakebase_text");
      expect(statements.some((statement) => statement.includes("USING lakebase_bm25"))).toBe(true);
    } else {
      expect(statements.some((statement) => statement.includes("USING gin"))).toBe(true);
    }
  });

  it("rejects duplicate or unstable ledger IDs", () => {
    expect(() => postgresMigrationConfigs([
      { id: "billing", path: "first" },
      { id: "billing", path: "second" },
    ])).toThrow("Duplicate PostgreSQL migration ledger ID: billing");
    expect(() => postgresMigrationConfigs([{ id: "Billing v2", path: "billing" }]))
      .toThrow("Invalid PostgreSQL migration ledger ID: Billing v2");
  });

  it("keeps generated auth migrations separate from the application baseline", () => {
    const [authDirectory, applicationDirectory] = serverMigrationManifest.postgres.directories;
    const authMigrations = readPostgresMigrations({ migrationsFolder: authDirectory!.path });
    const applicationMigrations = readPostgresMigrations({ migrationsFolder: applicationDirectory!.path });
    expect(authMigrations.map(({ name }) => name)).toEqual(["20260903034253_melodic_scalphunter"]);
    expect(applicationMigrations.map(({ name }) => name)).toEqual(["20260903173551_bumpy_freak"]);
    expect([...authMigrations, ...applicationMigrations].every(({ hash, sql }) => hash.length === 64 && sql.length > 0))
      .toBe(true);
    const authSql = authMigrations.flatMap((migration) => migration.sql).join("\n");
    const sql = applicationMigrations.flatMap((migration) => migration.sql).join("\n");
    const snapshot = readFileSync(
      new URL("../drizzle/postgres/20260903173551_bumpy_freak/snapshot.json", import.meta.url),
      "utf8",
    );
    expect(authSql).toContain('CREATE TABLE "auth"."user"');
    expect(authSql).not.toContain('CREATE SCHEMA "core"');
    expect(authSql).not.toContain('CREATE SCHEMA "content"');
    expect(sql).not.toContain('CREATE SCHEMA "auth"');
    expect(sql).toContain('FROM "auth"."member"');
    expect(sql).not.toContain('CREATE TABLE "auth"."member"');
    expect(sql).toContain('CREATE TABLE "core"."model_alias"');
    expect(sql).toContain('CREATE TABLE "core"."artifact"');
    expect(sql).toContain('CREATE TABLE "core"."vaults"');
    expect(sql).toContain('CREATE TABLE "core"."vault_permissions"');
    expect(sql).toContain('"granted_by_user_id" text NOT NULL');
    expect(sql).not.toContain('"granted_by_principal_id"');
    expect(sql).toContain('CONSTRAINT "vault_permission_granted_by_user_fk"');
    expect(sql).toContain('CONSTRAINT "search_index_job_owner_user_fk"');
    expect(sql).toContain('REFERENCES "auth"."user"("id")');
    expect(sql).toContain('CREATE TABLE "content"."meetings"');
    expect(sql).toContain('CREATE TABLE "content"."transcript_segments"');
    expect(sql).toContain('CREATE TABLE "content"."screenshots"');
    expect(sql).toContain('CREATE TABLE "content"."search_documents"');
    expect(sql).toContain('CREATE TABLE "content"."search_embeddings"');
    expect(sql).toContain('CREATE TABLE "core"."search_index_jobs"');
    expect(sql).toContain('"search_text" text DEFAULT \'\' NOT NULL');
    expect(sql).toContain("tsvector GENERATED ALWAYS AS (to_tsvector('simple', search_text)) STORED");
    expect(sql).toContain('"embedding" real[] NOT NULL');
    expect(sql).toContain('"vault_id" uuid');
    expect(sql).toContain('"meeting_id" uuid');
    expect(sql).toContain('"screenshot_id" uuid');
    expect(sql).toContain('"segment_id" uuid');
    expect(sql).not.toContain("artifact_reservation");
    expect(sql).toContain('CREATE SCHEMA "core"');
    expect(sql).toContain('CREATE SCHEMA "content"');
    expect(sql).toContain("FORCE ROW LEVEL SECURITY");
    expect(sql).toContain("CREATE POLICY");
    expect(sql).toContain("current_setting('app.user_id', true)");
    expect(sql).not.toContain("SET search_path = pg_catalog");
    expect(sql).toContain('FROM "auth"."member"');
    expect(sql).not.toContain("dahlia.organization_ids");
    expect(sql).not.toContain("dahlia.deployment_principal_id");
    expect(sql).not.toContain("dahlia.sync_sharing_enabled");
    expect(sql).toContain('CREATE UNIQUE INDEX "vault_permission_single_owner_idx"');
    expect(sql).toContain('CREATE INDEX "member_user_organization_idx" ON "auth"."member" ("user_id","organization_id")');
    expect(sql).toContain('CREATE INDEX "team_member_user_team_idx" ON "auth"."team_member" ("user_id","team_id")');
    expect(sql).toContain('"core"."current_identity_can_read_vault"("vault_id")');
    expect(sql).not.toContain('ALTER TABLE "core"."vault_permissions" ENABLE ROW LEVEL SECURITY');
    expect(sql).toContain('ALTER TABLE "content"."search_documents" FORCE ROW LEVEL SECURITY');
    expect(sql).toContain('ALTER TABLE "content"."search_embeddings" FORCE ROW LEVEL SECURITY');
    for (const policy of [
      "vault_select",
      "vault_insert",
      "vault_update",
      "vault_delete",
      "project_select",
      "project_insert",
      "project_update",
      "project_delete",
      "meeting_select",
      "meeting_write",
      "transcript_select",
      "transcript_write",
      "transcript_patch_select",
      "transcript_patch_write",
      "screenshot_select",
      "screenshot_write",
      "transaction_receipt_owner",
      "search_document_select",
      "search_document_write",
      "search_embedding_select",
      "search_embedding_write",
    ]) {
      expect(snapshot).toContain(`"name": "${policy}"`);
    }
    expect(sql).not.toContain('FOREIGN KEY ("owner_workspace_id")');
    for (const table of ["meetings", "transcript_segments", "screenshots"]) {
      const definition = sql.match(new RegExp(`CREATE TABLE "content"\\."${table}" \\(([\\s\\S]*?)\\n\\);`))?.[1];
      expect(definition).toBeDefined();
      expect(definition).not.toContain("owner_workspace_id");
      expect(definition).not.toContain("search_text");
    }
    expect(sql).not.toContain('"public".');
    expect(readFileSync(new URL("../src/db/client.ts", import.meta.url), "utf8")).not.toContain("createLakebasePool");
  });

  it("registers every committed Drizzle migration", () => {
    for (const dialect of ["postgres", "sqlite"] as const) {
      const migrationSet = serverMigrationManifest[dialect];
      for (const directory of migrationSet.directories) {
        expect(globSync("*/migration.sql", { cwd: directory.path }).toSorted())
          .toEqual(directory.files?.toSorted() ?? []);
      }
    }
  });
});
