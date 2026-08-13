import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import Stripe from "stripe";
import { afterEach, describe, expect, it } from "vitest";

import { createApp } from "../src/app";
import { initializeDahliaAuth } from "../src/auth/better-auth";
import { createNodeAuthStore } from "../src/auth/node-store";
import type { AppConfig } from "../src/config";

const directories: string[] = [];

function config(path: string): AppConfig {
  return {
    runtime: "custom",
    authProvider: "accounts",
    authHeader: "X-Forwarded-Email",
    authDatabase: "sqlite",
    authSqlitePath: path,
    baseUrl: "http://localhost:5173",
    googleClientId: "google-client",
    googleClientSecret: "google-secret",
    betterAuthSecret: "test-only-better-auth-secret-value",
    stripe: {
      secretKey: "sk_test_secret",
      webhookSecret: "whsec_test",
      proMonthlyPriceId: "price_pro",
    },
    oauthRedirectUris: ["http://127.0.0.1:1455/oauth/callback"],
    trustedProxyCidrs: [],
    maxRequestBytes: 1024,
  };
}

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true });
});

describe("Stripe webhook", () => {
  it("rejects tampering and synchronizes the subscription lifecycle", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-stripe-"));
    directories.push(directory);
    const path = join(directory, "auth.sqlite");
    const appConfig = config(path);
    const store = createNodeAuthStore(appConfig);
    await store.migrate();
    const stripeClient = new Stripe("sk_test_secret", { apiVersion: "2026-07-29.dahlia" });
    let currentSubscription: Stripe.Subscription;
    stripeClient.subscriptions.retrieve = async () => currentSubscription as Stripe.Response<Stripe.Subscription>;
    let failSynchronization = false;
    const authStore = {
      ...store,
      syncGatewayEntitlement: (...arguments_: Parameters<typeof store.syncGatewayEntitlement>) => (
        failSynchronization
          ? Promise.reject(new Error("database unavailable"))
          : store.syncGatewayEntitlement(...arguments_)
      ),
    };
    const auth = await initializeDahliaAuth(appConfig, authStore, stripeClient);
    const app = createApp({ config: appConfig, auth, authStore });
    const database = new DatabaseSync(path);
    const now = new Date().toISOString();
    database.prepare(
      `INSERT INTO "user" (
        "id", "name", "email", "emailVerified", "createdAt", "updatedAt", "stripeCustomerId"
      ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).run("user-1", "User", "user@example.com", 1, now, now, "cus_user");

    const unsigned = JSON.stringify({ id: "evt_tampered", object: "event", type: "ping", data: { object: {} } });
    const tampered = await app.request("/api/auth/stripe/webhook", {
      method: "POST",
      headers: { "content-type": "application/json", "stripe-signature": "tampered" },
      body: unsigned,
    });
    expect(tampered.status).toBe(400);

    async function send(type: string, status: string, expectedStatus = 200) {
      const eventSubscription = {
        id: "sub_user",
        object: "subscription",
        customer: "cus_user",
        status,
        metadata: {},
        cancel_at_period_end: false,
        cancel_at: null,
        canceled_at: null,
        ended_at: null,
        schedule: null,
        trial_start: null,
        trial_end: null,
        items: {
          data: [{
            id: "si_user",
            current_period_start: 1_786_000_000,
            current_period_end: 1_788_678_400,
            quantity: 1,
            price: { id: "price_pro", recurring: { interval: "month" } },
          }],
        },
      } as unknown as Stripe.Subscription;
      currentSubscription = eventSubscription;
      const payload = JSON.stringify({
        id: `evt_${status}`,
        object: "event",
        api_version: "2026-07-29.dahlia",
        created: 1_786_000_000,
        livemode: false,
        pending_webhooks: 1,
        request: null,
        type,
        data: {
          object: eventSubscription,
        },
      });
      const signature = Stripe.webhooks.generateTestHeaderString({ payload, secret: "whsec_test" });
      const response = await app.request("/api/auth/stripe/webhook", {
        method: "POST",
        headers: { "content-type": "application/json", "stripe-signature": signature },
        body: payload,
      });
      expect(response.status).toBe(expectedStatus);
    }

    await send("customer.subscription.created", "active");
    expect(await store.getBillingSubscription("user-1")).toMatchObject({ plan: "pro", status: "active" });
    expect(await store.getGatewayEntitlement("user-1")).toMatchObject({ plan: "pro", status: "active" });

    await send("customer.subscription.updated", "past_due");
    expect(await store.getBillingSubscription("user-1")).toMatchObject({ status: "past_due" });
    expect(await store.getGatewayEntitlement("user-1")).toMatchObject({ status: "past_due" });

    failSynchronization = true;
    await send("customer.subscription.updated", "active", 400);
    failSynchronization = false;
    expect(await store.getGatewayEntitlement("user-1")).toMatchObject({ status: "past_due" });

    await send("customer.subscription.deleted", "canceled");
    expect(await store.getBillingSubscription("user-1")).toMatchObject({ status: "canceled" });
    expect(await store.getGatewayEntitlement("user-1")).toMatchObject({ status: "canceled" });

    database.close();
    await store.close?.();
  });
});
