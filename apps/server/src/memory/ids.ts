import { decodeId, encodeId } from "../typeid";
import type { MemorySource } from "./model";

export function memoryBankId(scopeId: string, personal = false) {
  return `dahlia_${encodeId(personal ? "user" : "workspace", scopeId)}`;
}

export function memoryDocumentId(kind: MemorySource["kind"], sourceId: string) {
  return encodeId(kind === "meeting" ? "meeting" : "sharedMemory", sourceId);
}

// This establishes the source identity only. The caller must still authorize its scope.
export function memoryDocumentSource(documentId: string): Pick<MemorySource, "kind" | "id"> | null {
  for (const kind of ["meeting", "shared"] as const) {
    try { return { kind, id: decodeId(kind === "meeting" ? "meeting" : "sharedMemory", documentId) }; }
    catch { /* Try the other supported source kind. */ }
  }
  return null;
}
