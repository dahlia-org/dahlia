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
import { connectPostgresUrl } from "../src/db/postgres";
import { initializeWorkerApp } from "../src/worker";

describe("Worker initialization", () => {
  beforeEach(() => { close.mockClear(); vi.mocked(connectPostgresUrl).mockClear(); });

  it.each([undefined, "0", "48"])("forwards document deletion grace hours %s", async (graceHours) => {
    await expect(initializeWorkerApp({
      DAHLIA_AUTH_TYPE: "header", DAHLIA_STORAGE_BACKEND: "r2", DAHLIA_DATABASE_TYPE: "postgres",
      DAHLIA_DATABASE_URL: "postgresql://dahlia.example/dahlia",
      DAHLIA_DOCUMENT_DELETION_GRACE_HOURS: graceHours,
    })).rejects.toThrow("seed failed");
    expect(vi.mocked(initializeDahliaAuth).mock.calls.at(-1)?.[0].documentDeletionGraceHours)
      .toBe(graceHours === undefined ? 24 : Number(graceHours));
  });

  it.each([false, true])("requires an image transformer only for configured Memory images (binding: %s)", async (binding) => {
    const env = {
      DAHLIA_AUTH_TYPE: "header", DAHLIA_STORAGE_BACKEND: "r2", DAHLIA_DATABASE_TYPE: "postgres",
      DAHLIA_DATABASE_URL: "postgresql://dahlia.example/dahlia", DAHLIA_HINDSIGHT_URL: "https://memory.example/api",
      DAHLIA_HINDSIGHT_AUTH: "none",
      DAHLIA_MEMORY_QUEUE: { send: vi.fn(), sendBatch: vi.fn() },
      ...(binding ? { IMAGES: { input: vi.fn() } } : {}),
    };
    await expect(initializeWorkerApp({ ...env, DAHLIA_MEMORY_IMAGE_MODEL: "system.ai.gpt-6-luna" }))
      .rejects.toThrow(binding ? "seed failed" : "Memory image ingestion requires the IMAGES binding");
    expect(vi.mocked(connectPostgresUrl)).toHaveBeenCalledTimes(binding ? 1 : 0);
    await expect(initializeWorkerApp(env)).rejects.toThrow("seed failed");
  });

  it.each(["", " ", "old-prefix"])("rejects the removed bank prefix before opening the database (%j)", async (prefix) => {
    // Removed bindings may remain in a deployed Worker even though they are no longer in RuntimeSecrets.
    const env = { DAHLIA_HINDSIGHT_BANK_PREFIX: prefix, DAHLIA_AUTH_TYPE: "header" };
    await expect(initializeWorkerApp(env)).rejects.toThrow(
      "DAHLIA_HINDSIGHT_BANK_PREFIX is no longer supported; remove it and use a dedicated Hindsight endpoint and storage for each environment",
    );
    expect(close).not.toHaveBeenCalled();
    expect(vi.mocked(connectPostgresUrl)).not.toHaveBeenCalled();
  });

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
