import type Stripe from "stripe";
import { describe, expect, it, vi } from "vitest";

import { createApp, personalBillingMutationAllowed } from "../src/app";
import { authorizePersonalBillingReference } from "../src/auth/better-auth";
import type {
  AuthStore,
  BillingSubscriptionRecord,
  GatewayEntitlementRecord,
  GatewayEntitlementUpdate,
} from "../src/auth/store";
import { BillingService, isProEntitled, synchronizeStripeSubscription } from "../src/billing/service";
import type { AppConfig, StripeConfig } from "../src/config";
import { testStore } from "./test-store";

const stripeConfig: StripeConfig = {
  secretKey: "sk_test_secret",
  webhookSecret: "whsec_test",
  proMonthlyPriceId: "price_pro",
};

function subscription(status: string, plan = "pro"): BillingSubscriptionRecord {
  return {
    plan,
    status,
    stripeCustomerId: "cus_user",
    periodStart: new Date("2026-08-01T00:00:00Z"),
    periodEnd: new Date("2026-09-01T00:00:00Z"),
    cancelAtPeriodEnd: false,
    cancelAt: null,
    canceledAt: null,
    endedAt: null,
  };
}

function entitlement(status: string, plan = "pro"): GatewayEntitlementRecord {
  const record = subscription(status, plan);
  return {
    plan: record.plan,
    status: record.status,
    periodEnd: record.periodEnd,
    cancelAtPeriodEnd: record.cancelAtPeriodEnd,
    cancelAt: record.cancelAt,
    canceledAt: record.canceledAt,
    endedAt: record.endedAt,
  };
}

function stripeSubscription(status: Stripe.Subscription.Status): Stripe.Subscription {
  return {
    id: "sub_current",
    customer: "cus_user",
    status,
    metadata: {},
    items: {
      data: [{
        price: { id: "price_pro" },
        current_period_start: 1_786_000_000,
        current_period_end: 1_788_678_400,
      }],
    },
    cancel_at_period_end: false,
    cancel_at: null,
    canceled_at: status === "canceled" ? 1_786_100_000 : null,
    ended_at: status === "canceled" ? 1_786_100_000 : null,
  } as unknown as Stripe.Subscription;
}

function subscriptionEvent(
  status: Stripe.Subscription.Status,
  created: number,
  id = `evt_${status}`,
): Stripe.Event {
  return {
    id,
    created,
    type: "customer.subscription.updated",
    data: { object: stripeSubscription(status) },
  } as Stripe.Event;
}

function headerConfig(billing: boolean): AppConfig {
  return {
    runtime: "custom",
    authProvider: "header",
    authHeader: "X-Forwarded-Email",
    authDatabase: "sqlite",
    baseUrl: "https://dahlia.example",
    ...(billing ? { stripe: stripeConfig } : {}),
    oauthRedirectUris: [],
    trustedProxyCidrs: [],
    maxRequestBytes: 1024,
  };
}

describe("personal Stripe billing", () => {
  const activePeriod = new Date("2026-08-15T00:00:00Z");

  it.each([
    ["active", true],
    ["trialing", true],
    ["past_due", false],
    ["canceled", false],
    ["incomplete", false],
  ])("maps %s to Gateway entitlement=%s", (status, entitled) => {
    expect(isProEntitled(entitlement(status), activePeriod)).toBe(entitled);
  });

  it("does not entitle Free or missing subscriptions", () => {
    expect(isProEntitled(entitlement("active", "free"), activePeriod)).toBe(false);
    expect(isProEntitled(null, activePeriod)).toBe(false);
  });

  it("does not entitle a stale active subscription after its paid period ends", () => {
    expect(isProEntitled(
      { ...entitlement("active"), periodEnd: new Date("2020-01-01T00:00:00Z") },
      activePeriod,
    )).toBe(false);
  });

  it("synchronizes the signed webhook snapshot with its event generation", async () => {
    const syncGatewayEntitlement = vi.fn().mockResolvedValue("updated");
    const store = {
      getBillingReferenceId: vi.fn().mockResolvedValue("user-1"),
      syncGatewayEntitlement,
    } as unknown as AuthStore;
    const event = subscriptionEvent("canceled", 1_786_000_000, "evt_current");

    await synchronizeStripeSubscription(event, store, "price_pro");

    expect(syncGatewayEntitlement).toHaveBeenCalledWith(expect.objectContaining({
      referenceId: "user-1",
      status: "canceled",
      stripeSubscriptionId: "sub_current",
      eventCreated: 1_786_000_000,
      eventId: "evt_current",
    }));
  });

  it("fails a webhook when the current subscription cannot be persisted", async () => {
    const store = {
      getBillingReferenceId: vi.fn().mockResolvedValue("user-1"),
      syncGatewayEntitlement: vi.fn().mockRejectedValue(new Error("database unavailable")),
    } as unknown as AuthStore;
    const event = subscriptionEvent("active", 1, "evt_current");

    await expect(synchronizeStripeSubscription(event, store, "price_pro"))
      .rejects.toThrow("database unavailable");
  });

  it("never grants access while an older active webhook finishes after cancellation", async () => {
    let releaseOlderUpdate!: () => void;
    const olderUpdateBlocked = new Promise<void>((resolve) => { releaseOlderUpdate = resolve; });
    let blockOlderUpdate = true;
    let stored: GatewayEntitlementUpdate | null = null;
    const stripe = {} as Stripe;
    const store = {
      getBillingReferenceId: vi.fn().mockResolvedValue("user-1"),
      getGatewayEntitlement: vi.fn(async () => stored),
      syncGatewayEntitlement: vi.fn(async (update: GatewayEntitlementUpdate) => {
        if (blockOlderUpdate && update.eventCreated === 1) {
          blockOlderUpdate = false;
          await olderUpdateBlocked;
        }
        if (!stored || stored.eventCreated < update.eventCreated) {
          stored = update;
          return "updated";
        }
        return "stale";
      }),
    } as unknown as AuthStore;
    const older = synchronizeStripeSubscription(subscriptionEvent("active", 1), store, "price_pro");
    await vi.waitFor(() => expect(blockOlderUpdate).toBe(false));
    await synchronizeStripeSubscription(subscriptionEvent("canceled", 2), store, "price_pro");
    const billing = new BillingService(stripeConfig, store, stripe);
    await expect(billing.canUseGateway("user-1")).resolves.toBe(false);
    releaseOlderUpdate();
    await older;

    await expect(billing.canUseGateway("user-1")).resolves.toBe(false);
    expect(stored).toMatchObject({ status: "canceled", eventCreated: 2 });
  });

  it("only authorizes the signed-in user's reference", async () => {
    await expect(authorizePersonalBillingReference({ user: { id: "user-1" }, referenceId: "user-1" }))
      .resolves.toBe(true);
    await expect(authorizePersonalBillingReference({ user: { id: "user-1" }, referenceId: "user-2" }))
      .resolves.toBe(false);
    expect(personalBillingMutationAllowed("/api/auth/subscription/upgrade", {
      plan: "pro",
      referenceId: "user-2",
    }, "user-1")).toBe(false);
    expect(personalBillingMutationAllowed("/api/auth/subscription/upgrade", {
      plan: "pro",
      annual: true,
    }, "user-1")).toBe(false);
    expect(personalBillingMutationAllowed("/api/auth/subscription/upgrade", {
      plan: "pro",
      seats: 2,
    }, "user-1")).toBe(false);
  });

  it("normalizes the plan and latest Stripe invoices without exposing IDs", async () => {
    const store = {
      getBillingSubscription: vi.fn().mockResolvedValue(subscription("active")),
      getGatewayEntitlement: vi.fn().mockResolvedValue(entitlement("active")),
      getStripeCustomerId: vi.fn().mockResolvedValue("cus_user"),
    } as unknown as AuthStore;
    const stripe = {
      prices: { retrieve: vi.fn().mockResolvedValue({ unit_amount: 2000, currency: "usd" }) },
      invoices: { list: vi.fn().mockResolvedValue({ data: [{
        id: "in_secret",
        created: 1_786_000_000,
        currency: "usd",
        description: null,
        hosted_invoice_url: "https://invoice.example/hosted",
        invoice_pdf: "https://invoice.example/invoice.pdf",
        lines: { data: [{ description: "Dahlia Pro — August" }] },
        status: "paid",
        total: 2000,
      }] }) },
    } as unknown as Stripe;

    const summary = await new BillingService(stripeConfig, store, stripe).summary("user-1");

    expect(summary).toMatchObject({
      plan: "pro",
      status: "active",
      monthlyAmount: 2000,
      currency: "usd",
      renewsAt: "2026-09-01T00:00:00.000Z",
      paymentManagementAvailable: true,
      invoices: [{
        amount: 2000,
        description: "Dahlia Pro — August",
        status: "paid",
        hostedInvoiceUrl: "https://invoice.example/hosted",
        invoicePdfUrl: "https://invoice.example/invoice.pdf",
      }],
    });
    expect(JSON.stringify(summary)).not.toContain("in_secret");
    expect(JSON.stringify(summary)).not.toContain("cus_user");
  });

  it("returns 402 from both Gateway endpoints when billing is required", async () => {
    const app = createApp({
      config: headerConfig(true),
      authStore: testStore(),
      billing: {
        canUseGateway: vi.fn().mockResolvedValue(false),
        summary: vi.fn(),
      },
    });
    const headers = { "X-Forwarded-Email": "user@example.com" };

    expect((await app.request("/api/v1/models", { headers })).status).toBe(402);
    expect((await app.request("/api/v1/responses", { method: "POST", headers })).status).toBe(402);
  });

  it("keeps authenticated Gateway access open when billing is disabled", async () => {
    const app = createApp({ config: headerConfig(false), authStore: testStore() });
    const headers = { "X-Forwarded-Email": "user@example.com" };
    const response = await app.request("/api/v1/models", {
      headers,
    });

    expect(response.status).toBe(200);
    expect((await app.request("/api/billing/summary", { headers })).status).toBe(404);
    expect((await app.request("/api/models", { headers })).status).toBe(404);
    expect((await app.request("/api/ai-gateway/v1/models", { headers })).status).toBe(404);
  });

  it("returns capability flags instead of the authentication implementation", async () => {
    const app = createApp({ config: headerConfig(false), authStore: testStore() });
    const response = await app.request("/api/session", {
      headers: { "X-Forwarded-Email": "user@example.com" },
    });

    const body = await response.json();
    expect(body).toMatchObject({
      capabilities: { billing: false, sessions: false },
      user: { id: "user@example.com", email: "user@example.com" },
      workspace: { type: "personal" },
    });
    expect(JSON.stringify(body)).not.toContain("authMode");
  });
});
