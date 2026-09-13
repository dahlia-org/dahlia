import { z } from "zod";

import type { AppConfig } from "../config";

const emailSchema = z.email();

/** Local single-user mode falls back to this identity when the header carries nothing. */
export const LOCAL_SINGLE_USER_EMAIL = "local@example.com";

/** RFC 5321 maximum address length, applied so a header value cannot become an unbounded key. */
const MAX_IDENTITY_LENGTH = 320;

export interface HeaderIdentitySource {
  email: string;
  name?: string;
}

/** Validates and normalizes a proxy-supplied email; the only accepted form outside local single-user mode. */
export function headerEmail(value: string | null | undefined): string | null {
  const result = emailSchema.safeParse(value?.trim().toLowerCase());
  return result.success ? result.data : null;
}

/**
 * Normalizes one header identity value. Local single-user mode accepts any non-empty
 * value, including one that is not an email; every other deployment requires an email.
 */
export function headerIdentityValue(
  config: Pick<AppConfig, "localSingleUser">,
  value: string | null | undefined,
): string | null {
  const email = headerEmail(value);
  if (email || !config.localSingleUser) return email;
  const relaxed = value?.trim().toLowerCase();
  return relaxed && relaxed.length <= MAX_IDENTITY_LENGTH ? relaxed : null;
}

/** Only an address with a domain part can enroll into a domain Organization. */
export function hasEmailDomain(value: string): boolean {
  return value.lastIndexOf("@") > 0;
}

/**
 * The identity source for header authentication. The configured header still wins
 * whenever it carries a value; local single-user mode only supplies a fallback identity
 * when it does not. Every downstream projection stays identical.
 */
export function headerIdentitySource(
  config: Pick<AppConfig, "authHeader" | "localSingleUser">,
  headers: Headers | undefined,
): HeaderIdentitySource | null {
  const value = headerIdentityValue(config, headers?.get(config.authHeader));
  if (value) return { email: value, name: headers?.get("X-Forwarded-Preferred-Username")?.trim() || undefined };
  return config.localSingleUser ? { email: LOCAL_SINGLE_USER_EMAIL } : null;
}
