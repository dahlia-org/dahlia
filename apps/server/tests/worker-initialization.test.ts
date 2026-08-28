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

import { initializeWorkerApp } from "../src/worker";

describe("Worker initialization", () => {
  beforeEach(() => close.mockClear());

  it("closes PostgreSQL when authentication initialization fails", async () => {
    await expect(initializeWorkerApp({
      DAHLIA_AUTH_TYPE: "accounts",
      DAHLIA_DATABASE_TYPE: "postgres",
      DAHLIA_DATABASE_URL: "postgresql://dahlia.example/dahlia",
      BETTER_AUTH_SECRET: "test-only-better-auth-secret-value",
      GOOGLE_CLIENT_ID: "google-client",
      GOOGLE_CLIENT_SECRET: "google-secret",
    })).rejects.toThrow("seed failed");
    expect(close).toHaveBeenCalledOnce();
  });
});
