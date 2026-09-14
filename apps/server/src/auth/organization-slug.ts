import { z } from "zod";

export const organizationSlugPattern = /^(?:[a-z0-9_]|-)+$/;

export const createOrganizationSchema = z.object({
  name: z.string().trim().min(1).max(200),
  slug: z.string().min(1).max(200).regex(organizationSlugPattern),
  initialOwnerUserId: z.uuid(),
}).strict();
