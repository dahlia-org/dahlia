import { z } from "zod";

import type { AppConfig } from "../config";

const emailSchema = z.email();

/** Local single-user mode substitutes this identity for the proxy header. */
export const LOCAL_SINGLE_USER_EMAIL = "local@example.com";

export interface HeaderIdentitySource {
  email: string;
  name?: string;
}

/** The configured proxy header is the only external identity source. */
export function headerEmail(value: string | null | undefined): string | null {
  const result = emailSchema.safeParse(value?.trim().toLowerCase());
  return result.success ? result.data : null;
}

/**
 * The identity source for header authentication. Local single-user mode reads no
 * request header at all; every downstream projection stays identical.
 */
export function headerIdentitySource(
  config: Pick<AppConfig, "authHeader" | "localSingleUser">,
  headers: Headers | undefined,
): HeaderIdentitySource | null {
  if (config.localSingleUser) return { email: LOCAL_SINGLE_USER_EMAIL };
  const email = headerEmail(headers?.get(config.authHeader));
  if (!email) return null;
  return { email, name: headers?.get("X-Forwarded-Preferred-Username")?.trim() || undefined };
}
