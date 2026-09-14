import { z } from "zod";
import freeEmailDomains from "./free-email-domains.json";

const blockedDomains = new Set(freeEmailDomains);

export function isSharedEmailDomain(domain: string): boolean {
  const labels = domain.toLowerCase().split(".");
  return labels.some((_, index) => blockedDomains.has(labels.slice(index).join(".")));
}

const domain = z.string().trim().toLowerCase().max(253)
  .regex(/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/, "invalid_auto_join_domain");
export const autoJoinDomainsSchema = z.object({ domains: z.array(domain).max(50) }).strict();
export type AutoJoinDomains = z.infer<typeof autoJoinDomainsSchema>;
