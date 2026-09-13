import { describe, expect, it, vi } from "vitest";
import { readDatabricksAuthSecret } from "../src/databricks/secret";
import { loadConfig } from "../src/config";

const workspace = { host: "https://workspace.example.com", clientId: "app", clientSecret: "credential", tokenUrl: "https://workspace.example.com/oidc/v1/token" };
const secret = "test-uc-auth-secret-at-least-32-characters";
const env = { DAHLIA_AUTH_TYPE: "header", DAHLIA_AUTH_SECRET_DATABRICKS: "main.app.auth_secret", DATABRICKS_HOST: workspace.host, DATABRICKS_CLIENT_ID: workspace.clientId, DATABRICKS_CLIENT_SECRET: workspace.clientSecret };

describe("Unity Catalog authentication secret", () => {
  it("loads UC-only workspace configuration and validates the three-level name", () => {
    const config = loadConfig(env);
    expect(config.databricksAuthSecret).toBe("main.app.auth_secret");
    expect(config.databricksWorkspace).toEqual(workspace);
    expect(() => loadConfig({ ...env, DAHLIA_AUTH_SECRET_DATABRICKS: "main/secret" })).toThrow("catalog.schema.secret");
  });

  it("reads effective_value with an App token, without exposing the value in the request", async () => {
    const transport = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(Response.json({ access_token: "app-token", expires_in: 3600 }))
      .mockResolvedValueOnce(Response.json({ effective_value: secret }));
    expect(await readDatabricksAuthSecret(workspace, "main.app.auth_secret", transport)).toBe(secret);
    expect(transport).toHaveBeenLastCalledWith("https://workspace.example.com/api/2.1/unity-catalog/secrets/main.app.auth_secret?include_value=true", expect.objectContaining({ headers: { authorization: "Bearer app-token" }, redirect: "error" }));
  });

  it.each([
    [403, { error: secret }],
    [200, { value: secret }],
    [200, { effective_value: "short" }],
  ])("rejects unreadable or invalid secrets (%s)", async (status, body) => {
    const transport = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(Response.json({ access_token: "app-token", expires_in: 3600 }))
      .mockResolvedValueOnce(Response.json(body, { status }));
    await expect(readDatabricksAuthSecret(workspace, "main.app.auth_secret", transport)).rejects.toThrow();
  });
});
