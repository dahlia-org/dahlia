import { describe, expect, it } from "vitest";

import { globSync, readFileSync } from "node:fs";

import { postgresMigrationConfigs, readPostgresMigrations } from "../src/db/client";
import { createPostgresPool } from "../src/db/postgres";
import { serverMigrationManifest } from "../src/migrations";

describe("PostgreSQL migrations", () => {
  it("tracks each extension directory by stable ledger ID", () => {
    expect(postgresMigrationConfigs([
      { id: "server", path: "server" },
      { id: "billing", path: "billing" },
      { id: "analytics", path: "analytics" },
    ])).toEqual([
      { migrationsFolder: "server", migrationsSchema: "dahlia" },
      { migrationsFolder: "billing", migrationsSchema: "dahlia", migrationsTable: "__dahlia_billing_migrations" },
      { migrationsFolder: "analytics", migrationsSchema: "dahlia", migrationsTable: "__dahlia_analytics_migrations" },
    ]);
    expect(postgresMigrationConfigs([
      { id: "server", path: "server" },
      { id: "analytics", path: "analytics" },
      { id: "billing", path: "billing" },
    ])[2]).toEqual({
      migrationsFolder: "billing",
      migrationsSchema: "dahlia",
      migrationsTable: "__dahlia_billing_migrations",
    });
  });

  it("uses the connection owner for the Dahlia PostgreSQL schema", async () => {
    const pool = createPostgresPool("postgresql://dahlia@127.0.0.1:5432/dahlia", 1);
    expect(pool.options.options).toBe("-c search_path=dahlia");
    await pool.end();
  });

  it("rejects duplicate or unstable ledger IDs", () => {
    expect(() => postgresMigrationConfigs([
      { id: "billing", path: "first" },
      { id: "billing", path: "second" },
    ])).toThrow("Duplicate PostgreSQL migration ledger ID: billing");
    expect(() => postgresMigrationConfigs([{ id: "Billing v2", path: "billing" }]))
      .toThrow("Invalid PostgreSQL migration ledger ID: Billing v2");
  });

  it("reads the committed auth and Dahlia schema baseline", () => {
    const migrationsFolder = serverMigrationManifest.postgres.directories[0]!.path;
    const migrations = readPostgresMigrations({ migrationsFolder });
    expect(migrations.map(({ name }) => name)).toEqual([
      "20260830001527_open_blue_shield",
    ]);
    expect(migrations.every(({ hash, sql }) => hash.length === 64 && sql.length > 0)).toBe(true);
    const sql = migrations.flatMap((migration) => migration.sql).join("\n");
    expect(sql).toContain('CREATE TABLE "user"');
    expect(sql).toContain('CREATE TABLE "model_alias"');
    expect(sql).toContain('CREATE TABLE "artifact"');
    expect(sql).toContain('CREATE TABLE "artifact_reservation"');
    expect(sql).not.toContain("CREATE SCHEMA");
    expect(sql).not.toContain('"auth".');
    expect(sql).not.toContain('"dahlia".');
    expect(sql).not.toContain('FOREIGN KEY ("owner_workspace_id")');
    expect(sql).not.toContain('"public".');
    expect(readFileSync(new URL("../src/db/client.ts", import.meta.url), "utf8")).not.toContain("createLakebasePool");
  });

  it("registers every committed Drizzle migration", () => {
    for (const dialect of ["postgres", "sqlite"] as const) {
      const migrationSet = serverMigrationManifest[dialect];
      const registered = migrationSet.files
        .map((file) => file.split("/").slice(-2).join("/"))
        .toSorted();
      expect(globSync("*/migration.sql", { cwd: migrationSet.directories[0]!.path }).toSorted())
        .toEqual(registered);
    }
  });
});
