import { z } from "zod";
import freeEmailDomains from "./free-email-domains.json";

const blockedDomains = new Set(freeEmailDomains);

export function isSharedEmailDomain(domain: string): boolean {
  const labels = domain.toLowerCase().split(".");
  return labels.some((_, index) => blockedDomains.has(labels.slice(index).join(".")));
}

const domain = z.string().trim().toLowerCase().max(253)
  .regex(/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/, "invalid_organization_domain");
export const joinPolicySchema = z.enum(["invite_only", "need_approval", "auto_join"]);
export const organizationDomainsSchema = z.object({ domains: z.array(z.object({ domain, joinPolicy: joinPolicySchema.default("invite_only") }).strict()).max(10) }).strict();
export type OrganizationDomains = z.infer<typeof organizationDomainsSchema>;
