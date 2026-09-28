import { canonicalJson } from "../sync/service";
import { contentHash } from "./sources";
import { MEMORY_MISSION, PERSONAL_MEMORY_MISSION, type MemorySource } from "./model";

// This identifies a projection recipe, never canonical evidence or content truth.
export function ingestionFingerprint(hash: string, source: MemorySource, policy: string) {
  return contentHash(canonicalJson({ version: 1, contentHash: hash, source, policy }));
}

// Bump assemblyVersion when the source assembly/extraction contract changes.
export function ingestionPolicy(upstream: string, images?: import("./images").ImageSettings) {
  return contentHash(canonicalJson({ assemblyVersion: 2, identifierVersion: 1, upstream, images: images ?? null, mission: MEMORY_MISSION, personalMission: PERSONAL_MEMORY_MISSION }));
}
