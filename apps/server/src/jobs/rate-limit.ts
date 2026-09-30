/** An upstream 429 pauses a store's unreferenced claims so parallel worker loops stop adding load. */
// ponytail: fixed cooldown; honor Retry-After once an upstream provider returns it.
export const RATE_LIMIT_COOLDOWN_MS = 30_000;

export const isRateLimited = (code: string) => code.endsWith("_http_429");
