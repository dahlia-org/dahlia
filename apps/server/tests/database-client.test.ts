import { describe, expect, it } from "vitest";

import { readFileSync } from "node:fs";

import { postgresMigrationConfigs, readPostgresMigrations } from "../src/db/client";
import { serverMigrationManifest } from "../src/migrations";

describe("PostgreSQL migrations", () => {
  it("tracks each extension directory by stable ledger ID", () => {
    expect(postgresMigrationConfigs([
      { id: "server", path: "server" },
      { id: "billing", path: "billing" },
      { id: "analytics", path: "analytics" },
    ])).toEqual([
      { migrationsFolder: "server" },
      { migrationsFolder: "billing", migrationsTable: "__dahlia_billing_migrations" },
      { migrationsFolder: "analytics", migrationsTable: "__dahlia_analytics_migrations" },
    ]);
    expect(postgresMigrationConfigs([
      { id: "server", path: "server" },
      { id: "analytics", path: "analytics" },
      { id: "billing", path: "billing" },
    ])[2]).toEqual({ migrationsFolder: "billing", migrationsTable: "__dahlia_billing_migrations" });
  });

  it("rejects duplicate or unstable ledger IDs", () => {
    expect(() => postgresMigrationConfigs([
      { id: "billing", path: "first" },
      { id: "billing", path: "second" },
    ])).toThrow("Duplicate PostgreSQL migration ledger ID: billing");
    expect(() => postgresMigrationConfigs([{ id: "Billing v2", path: "billing" }]))
      .toThrow("Invalid PostgreSQL migration ledger ID: Billing v2");
  });

  it("reads the committed legacy Drizzle journal without rewriting released migrations", () => {
    const migrationsFolder = serverMigrationManifest.postgres.directories[0]!.path;
    const migrations = readPostgresMigrations({ migrationsFolder });
    expect(migrations.map(({ name }) => name)).toEqual(["0000_solid_ted_forrester", "0001_server"]);
    expect(migrations.every(({ hash, sql }) => hash.length === 64 && sql.length > 0)).toBe(true);
    expect(readFileSync(new URL("../src/db/client.ts", import.meta.url), "utf8")).not.toContain("createLakebasePool");
  });
});
