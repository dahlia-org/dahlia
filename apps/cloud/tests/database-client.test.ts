import { describe, expect, it, vi } from "vitest";

import type { DatabricksDatabaseConfig } from "../src/config";
import { databricksDatabasePassword } from "../src/db/client";

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
