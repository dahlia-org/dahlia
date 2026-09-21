import { beforeEach, describe, expect, it, vi } from "vitest";

const close = vi.fn(async () => undefined);

vi.mock("../src/db/postgres", () => ({
  connectPostgresUrl: vi.fn(() => ({ db: {}, close })),
}));
vi.mock("../src/auth/better-auth", async (importOriginal) => ({
  ...await importOriginal<typeof import("../src/auth/better-auth")>(),
  initializeDahliaAuth: vi.fn(async () => {
    throw new Error("seed failed");
  }),
}));

import { initializeDahliaAuth } from "../src/auth/better-auth";
import { initializeWorkerApp } from "../src/worker";

describe("Worker initialization", () => {
  beforeEach(() => close.mockClear());

  it.each([undefined, "0", "1"])("forwards signup policy %s and closes PostgreSQL when authentication initialization fails", async (signupPolicy) => {
    await expect(initializeWorkerApp({
      DAHLIA_ENCRYPTION_MASTER_KEY_3: btoa(String.fromCharCode(...new Uint8Array(32).fill(3))),
      DAHLIA_ENCRYPTION_ACTIVE_KEY_ID: "3",
      DAHLIA_AUTH_TYPE: "accounts",
      DAHLIA_AUTO_CREATE_ORG_ON_SIGNUP: signupPolicy,
      DAHLIA_AUTH_PROVIDER_ID: "databricks",
      DAHLIA_SIGNOUT_URL: "/.auth/logout",
      DAHLIA_STORAGE_BACKEND: "r2",
      DAHLIA_DATABASE_TYPE: "postgres",
      DAHLIA_DATABASE_URL: "postgresql://dahlia.example/dahlia",
      DAHLIA_AUTH_SECRET: "test-only-better-auth-secret-value",
      GOOGLE_CLIENT_ID: "google-client",
      GOOGLE_CLIENT_SECRET: "google-secret",
    })).rejects.toThrow("seed failed");
    expect(vi.mocked(initializeDahliaAuth).mock.calls.at(-1)?.[0].encryption?.activeKeyId).toBe("3");
    expect(vi.mocked(initializeDahliaAuth).mock.calls.at(-1)?.[0].authProviderId).toBe("databricks");
    expect(vi.mocked(initializeDahliaAuth).mock.calls.at(-1)?.[0].signOutUrl).toBe("/.auth/logout");
    expect(vi.mocked(initializeDahliaAuth).mock.calls.at(-1)?.[0].autoCreateOrgOnSignup).toBe(signupPolicy === "1");
    expect(close).toHaveBeenCalledOnce();
  });
});
