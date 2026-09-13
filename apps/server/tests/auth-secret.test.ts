import { afterEach, describe, expect, it, vi } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveAuthSecret } from "../src/auth/secret";
import { loadConfig } from "../src/config";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeAuthStore } from "../src/auth/node-store";

const directories: string[] = [];
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});
function directory() {
  const path = mkdtempSync(join(tmpdir(), "dahlia-auth-secret-"));
  directories.push(path);
  const cwd = vi.spyOn(process, "cwd").mockReturnValue(path);
  return { path, cwd };
}

describe("authentication secret", () => {
  it("uses the configured value unchanged without filesystem access", async () => {
    const { path, cwd } = directory();
    const secret = " test-auth-secret-at-least-32-characters ";
    expect(loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_AUTH_SECRET: secret }).betterAuthSecret).toBe(secret);
    expect(await resolveAuthSecret(secret)).toBe(secret);
    expect(cwd).not.toHaveBeenCalled();
    expect(existsSync(join(path, "dahlia-auth-secret"))).toBe(false);
    writeFileSync(join(path, "dahlia-auth-secret"), "invalid");
    expect(await resolveAuthSecret(secret)).toBe(secret);
    expect(readFileSync(join(path, "dahlia-auth-secret"), "utf8")).toBe("invalid");
  });

  it("allows an absent or empty variable and ignores the old variable", () => {
    for (const env of [{}, { DAHLIA_AUTH_SECRET: "" }, { BETTER_AUTH_SECRET: "old-secret-at-least-32-characters" }]) {
      expect(loadConfig({ DAHLIA_AUTH_TYPE: "header", ...env }).betterAuthSecret).toBeUndefined();
    }
    expect(() => loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_AUTH_SECRET: "short" })).toThrow("unique random value");
  });

  it("creates one private secret and reuses it across initializers and processes", async () => {
    const { path } = directory();
    const secrets = await Promise.all(Array.from({ length: 8 }, () => resolveAuthSecret()));
    expect(new Set(secrets).size).toBe(1);
    expect(secrets[0]).toMatch(/^[0-9a-f]{64}$/);
    expect(statSync(join(path, "dahlia-auth-secret")).mode & 0o777).toBe(0o600);
    const before = statSync(join(path, "dahlia-auth-secret")).mtimeMs;
    const moduleUrl = new URL("../src/auth/secret.ts", import.meta.url).href;
    execFileSync(process.execPath, ["--import", import.meta.resolve("tsx"), "--input-type=module", "-e", `
      import assert from 'node:assert/strict';
      import { readFileSync } from 'node:fs';
      const { resolveAuthSecret } = await import(${JSON.stringify(moduleUrl)});
      assert.ok(await resolveAuthSecret() === readFileSync('dahlia-auth-secret', 'utf8'), 'secret changed across processes');
    `], { cwd: path, stdio: "pipe" });
    expect(statSync(join(path, "dahlia-auth-secret")).mtimeMs).toBe(before);
  });

  it("does not overwrite invalid files or replace filesystem failures with another secret", async () => {
    const { path, cwd } = directory();
    const file = join(path, "dahlia-auth-secret");
    writeFileSync(file, "short");
    await expect(resolveAuthSecret()).rejects.toThrow("unique random value");
    expect(readFileSync(file, "utf8")).toBe("short");
    rmSync(file);
    mkdirSync(file);
    await expect(resolveAuthSecret()).rejects.toMatchObject({ code: "EISDIR" });
    cwd.mockReturnValue(join(path, "missing"));
    await expect(resolveAuthSecret()).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("keeps a browser session valid after the store and auth runtime restart", async () => {
    const { path } = directory();
    const config = loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_DATABASE_URL: `file:${join(path, "auth.sqlite")}` });
    let store = createNodeAuthStore(config);
    try {
      await store.migrate();
      const auth = await initializeDahliaAuth(config, store);
      const response = await auth.handler(new Request(`${config.baseUrl}/api/auth/header/sign-in`, {
        method: "POST", headers: { origin: config.baseUrl, "X-Forwarded-Email": "secret-test@example.com" },
      }));
      expect(response.status).toBe(200);
      const headers = { cookie: response.headers.getSetCookie().map((value) => value.split(";")[0]).join("; ") };
      const original = await auth.api.getSession({ headers });
      expect(original?.user.email).toBe("secret-test@example.com");
      await store.close?.();
      store = createNodeAuthStore(config);
      const restarted = await initializeDahliaAuth(config, store);
      expect((await restarted.api.getSession({ headers }))?.session.id).toBe(original?.session.id);
    } finally { await store.close?.(); }
  });

  it("does not fall back to a file when the configured UC secret cannot be read", async () => {
    const { path } = directory();
    const config = loadConfig({ DAHLIA_AUTH_TYPE: "header", DAHLIA_DATABASE_URL: `file:${join(path, "auth.sqlite")}` });
    config.databricksAuthSecret = "main.app.auth_secret";
    config.databricksWorkspace = { host: "https://workspace.example.com", tokenUrl: "https://workspace.example.com/oidc/v1/token", clientId: "app", clientSecret: "credential" };
    const transport = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(Response.json({ access_token: "app-token", expires_in: 3600 }))
      .mockResolvedValueOnce(Response.json({}, { status: 403 }));
    vi.stubGlobal("fetch", transport);
    const store = createNodeAuthStore(config);
    try {
      await store.migrate();
      await expect(initializeDahliaAuth(config, store)).rejects.toThrow("retrieval failed (403)");
      expect(existsSync(join(path, "dahlia-auth-secret"))).toBe(false);
      config.betterAuthSecret = "test-explicit-secret-at-least-32-characters";
      await initializeDahliaAuth(config, store);
      expect(transport).toHaveBeenCalledTimes(2);
      expect(existsSync(join(path, "dahlia-auth-secret"))).toBe(false);
    } finally { await store.close?.(); }
  });
});
