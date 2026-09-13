import { z } from "zod";

const emailSchema = z.email();

/** The configured proxy header is the only external identity source. */
export function headerEmail(value: string | null | undefined): string | null {
  const result = emailSchema.safeParse(value?.trim().toLowerCase());
  return result.success ? result.data : null;
}
