import { expect, it } from "vitest";
import { createApp } from "../src/app";
import { loadConfig } from "../src/config";
import { testStore } from "./test-store";

it("removes the obsolete account language settings endpoint", async () => {
  const app = createApp({ config: loadConfig({ DAHLIA_AUTH_SECRET: "test-better-auth-secret-at-least-32-characters", DAHLIA_AUTH_TYPE: "header" }), authStore: testStore() });
  const response = await app.request("/api/v1/account/settings", { method: "PATCH", headers: { "x-forwarded-email": "owner@example.com" } });
  expect(response.status).toBe(404);
});
