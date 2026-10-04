import { z } from "zod";

export const organizationSlugPattern = /^(?:[a-z0-9_]|-)+$/;
export const isReservedTeamOrganizationSlug = (slug: string) => slug.toLowerCase().startsWith("personal-");

export function organizationSlugFromName(name: string): string {
  const normalized = name.normalize("NFKC").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  const slug = normalized || "organization";
  return `${isReservedTeamOrganizationSlug(slug) ? "team-" : ""}${slug}`.slice(0, 200).replace(/-+$/, "");
}

export const createOrganizationSchema = z.object({
  name: z.string().trim().min(1).max(200),
  slug: z.string().min(1).max(200).regex(organizationSlugPattern),
  initialOwnerUserId: z.uuid(),
}).strict();
