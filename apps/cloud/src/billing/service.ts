import Stripe from "stripe";

import type { AuthStore, GatewayEntitlementRecord } from "../auth/store";
import type { StripeConfig } from "../config";

export interface BillingInvoice {
  amount: number;
  createdAt: string;
  currency: string;
  description: string;
  hostedInvoiceUrl: string | null;
  invoicePdfUrl: string | null;
  status: string;
}

export interface BillingSummary {
  plan: "free" | "pro";
  status: string;
  monthlyAmount: number;
  currency: string;
  renewsAt: string | null;
  endsAt: string | null;
  paymentManagementAvailable: boolean;
  invoices: BillingInvoice[];
}

export function isProEntitled(subscription: GatewayEntitlementRecord | null, now = new Date()): boolean {
  return subscription?.plan === "pro"
    && (subscription.status === "active" || subscription.status === "trialing")
    && subscription.periodEnd !== null
    && subscription.periodEnd > now;
}

export async function synchronizeStripeSubscription(
  event: Stripe.Event,
  authStore: AuthStore,
  priceId: string,
): Promise<void> {
  if (!event.type.startsWith("customer.subscription.")) return;
  const subscription = event.data.object as Stripe.Subscription;
  const item = subscription.items.data.find((candidate) => candidate.price.id === priceId);
  if (!item) throw new Error(`Stripe subscription ${subscription.id} does not contain the configured Pro price`);
  const referenceId = await authStore.getBillingReferenceId(subscription.id);
  if (!referenceId) throw new Error(`Stripe subscription ${subscription.id} is not linked to a Dahlia account`);

  await authStore.syncGatewayEntitlement({
    referenceId,
    plan: "pro",
    status: subscription.status,
    stripeSubscriptionId: subscription.id,
    periodEnd: new Date(item.current_period_end * 1000),
    cancelAtPeriodEnd: subscription.cancel_at_period_end,
    cancelAt: subscription.cancel_at ? new Date(subscription.cancel_at * 1000) : null,
    canceledAt: subscription.canceled_at ? new Date(subscription.canceled_at * 1000) : null,
    endedAt: subscription.ended_at ? new Date(subscription.ended_at * 1000) : null,
    eventCreated: event.created,
    eventId: event.id,
  });
}

export class BillingService {
  private readonly stripe: Stripe;

  constructor(
    private readonly config: StripeConfig,
    private readonly authStore: AuthStore,
    stripeClient?: Stripe,
  ) {
    this.stripe = stripeClient ?? new Stripe(config.secretKey, { apiVersion: "2026-07-29.dahlia" });
  }

  async canUseGateway(userId: string): Promise<boolean> {
    return isProEntitled(await this.authStore.getGatewayEntitlement(userId));
  }

  async summary(userId: string): Promise<BillingSummary> {
    const [entitlement, subscription, userCustomerId, price] = await Promise.all([
      this.authStore.getGatewayEntitlement(userId),
      this.authStore.getBillingSubscription(userId),
      this.authStore.getStripeCustomerId(userId),
      this.stripe.prices.retrieve(this.config.proMonthlyPriceId),
    ]);
    const customerId = userCustomerId ?? subscription?.stripeCustomerId ?? null;
    const invoicePage = customerId
      ? await this.stripe.invoices.list({ customer: customerId, limit: 12 })
      : { data: [] };
    const pro = entitlement?.plan === "pro";
    const periodEnd = entitlement?.periodEnd?.toISOString() ?? null;

    return {
      plan: pro ? "pro" : "free",
      status: entitlement?.status ?? "free",
      monthlyAmount: pro ? (price.unit_amount ?? 0) : 0,
      currency: price.currency,
      renewsAt: entitlement
        && (entitlement.status === "active" || entitlement.status === "trialing")
        && !entitlement.cancelAtPeriodEnd
        ? periodEnd
        : null,
      endsAt: entitlement?.cancelAt?.toISOString()
        ?? (entitlement?.cancelAtPeriodEnd ? periodEnd : null)
        ?? entitlement?.endedAt?.toISOString()
        ?? null,
      paymentManagementAvailable: customerId !== null,
      invoices: invoicePage.data.map((invoice) => ({
        amount: invoice.total,
        createdAt: new Date(invoice.created * 1000).toISOString(),
        currency: invoice.currency,
        description: invoice.description ?? invoice.lines.data[0]?.description ?? "Dahlia Pro",
        hostedInvoiceUrl: invoice.hosted_invoice_url ?? null,
        invoicePdfUrl: invoice.invoice_pdf ?? null,
        status: invoice.status ?? "unknown",
      })),
    };
  }
}
