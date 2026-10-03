import { mergeDocumentUpdates } from "./core";

export const documentSendInterval = 2_000;
export interface PendingDocumentUpdate { sequence: number; update: string }
/** Acknowledgements always cover the captured batch, never edits appended during the request. */
export function documentSendBatch(pending: PendingDocumentUpdate[]) {
  return { update: pending.length ? mergeDocumentUpdates(pending.map((entry) => entry.update)) : undefined,
    through: pending.at(-1)?.sequence ?? null };
}
export function documentReplyVersion(current: { generation: string | null; revision: number }, incoming: { generation: string | null; revision: number }) {
  if (current.generation && incoming.generation !== current.generation) throw new Error("document_generation_changed");
  return { generation: incoming.generation, revision: Math.max(current.revision, incoming.revision) };
}
