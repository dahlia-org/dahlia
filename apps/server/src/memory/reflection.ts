import { z } from "zod";

// Bounds also limit lineage lookups. Overflow is rejected, never silently truncated.
export const reflectionClaimsSchema = z.object({ claims: z.array(z.object({
  text: z.string().trim().min(1).max(4000).describe("A source-backed hypothesis, not a verified fact or a canonical quotation."),
  factIds: z.array(z.string().min(1).max(200)).min(1).max(10).describe("Exact memory or observation IDs cited for this claim in the answer. Never invent IDs or use mental-model or directive IDs."),
}).strict()).max(10) }).strict();

export const reflectionResponseSchema = z.toJSONSchema(reflectionClaimsSchema);
export const reflectionStatusSchema = z.enum(["not_requested", "ready", "partial", "invalid_references",
  "missing_output", "structured_error", "invalid_output", "empty", "temporal_unavailable", "updating"]);
export type ReflectionStatus = z.infer<typeof reflectionStatusSchema>;
export interface MemoryClaim {
  text: string;
  citations: Array<{ factId: string; sourceIndexes: number[] }>;
}

export function parseReflection(response: { structured_output?: unknown; structured_output_error?: string | null }) {
  if (response.structured_output_error != null) return { status: "structured_error" as const, claims: [], totalClaims: 0 };
  if (response.structured_output == null) return { status: "missing_output" as const, claims: [], totalClaims: 0 };
  const parsed = z.object({ claims: z.array(z.unknown()).max(10) }).strict().safeParse(response.structured_output);
  if (!parsed.success) return { status: "invalid_output" as const, claims: [], totalClaims: 0 };
  const claims = parsed.data.claims.flatMap((claim) => {
    const parsedClaim = reflectionClaimsSchema.shape.claims.element.safeParse(claim);
    return parsedClaim.success ? [parsedClaim.data] : [];
  });
  return { status: claims.length ? "ready" as const : parsed.data.claims.length ? "invalid_output" as const : "empty" as const,
    claims, totalClaims: parsed.data.claims.length };
}
