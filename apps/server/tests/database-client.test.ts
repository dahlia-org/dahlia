import { describe, expect, it, vi } from "vitest";

import type { DatabricksDatabaseConfig } from "../src/config";
import { databricksDatabasePassword, postgresMigrationConfigs } from "../src/db/client";

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
});

describe("Databricks Lakebase credentials", () => {
  it("mints and caches a short-lived database password without exposing service credentials", async () => {
    const credentials: Pick<DatabricksDatabaseConfig, "workspaceUrl" | "clientId" | "clientSecret"> = {
      workspaceUrl: "https://workspace.cloud.databricks.com",
      clientId: "service-principal",
      clientSecret: "service-secret",
    };
    const transport = vi.fn<typeof fetch>(async (input, init) => {
      const url = String(input);
      if (url.endsWith("/oidc/v1/token")) return Response.json({ access_token: "workspace-token" });
      expect(new Headers(init?.headers).get("authorization")).toBe("Bearer workspace-token");
      expect(init?.body).toBe(JSON.stringify({ endpoint: "projects/project/branches/main/endpoints/app" }));
      return Response.json({ token: "database-token", expire_time: "2099-01-01T00:00:00Z" });
    });
    const password = databricksDatabasePassword(
      credentials,
      "projects/project/branches/main/endpoints/app",
      transport,
    );

    await expect(Promise.all([password(), password()])).resolves.toEqual(["database-token", "database-token"]);
    await expect(password()).resolves.toBe("database-token");
    expect(transport).toHaveBeenCalledTimes(2);
    expect(JSON.stringify(transport.mock.calls)).not.toContain("service-secret");
  });
});
