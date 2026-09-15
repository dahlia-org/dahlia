import { z } from "zod";

export const organizationSlugPattern = /^(?:[a-z0-9_]|-)+$/;

export function organizationSlugFromName(name: string): string {
  const normalized = name.normalize("NFKC").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return normalized.slice(0, 200).replace(/-+$/, "") || "organization";
}

export const createOrganizationSchema = z.object({
  name: z.string().trim().min(1).max(200),
  slug: z.string().min(1).max(200).regex(organizationSlugPattern),
  initialOwnerUserId: z.uuid(),
}).strict();
