import { DocumentCore, mergeDocumentUpdates, removedBlocks } from "./core";

import { documentSendBatch, type PendingDocumentUpdate } from "./transport";

interface Command {
  pending?: PendingDocumentUpdate[];
  checkpoint?: string;
  updates?: string[];
  text?: string;
  vector?: string;
  purgeBefore?: number;
  local?: boolean;
}

/** JSON-only boundary: JSValue and Yjs objects never cross the owning JSC thread. */
export function run(json: string): string {
  const command = JSON.parse(json) as Command;
  const core = new DocumentCore(command.checkpoint);
  try {
    const before = core.projection(false);
    for (const update of command.updates ?? []) core.apply(update);
    if (command.text !== undefined) core.insertText(command.text, () => crypto.randomUUID());
    const removed = removedBlocks(before, core.projection(false));
    const purged = command.purgeBefore !== undefined && core.purgeDeletedBlocks(command.purgeBefore) > 0;
    const projection = core.projection(command.local === true);
    const checkpoint = core.checkpoint(command.local === true);
    return JSON.stringify({ checkpoint, vector: core.vector(), projection,
      update: command.vector ? core.difference(command.vector) : checkpoint,
      removed, purged,
      batch: command.pending ? documentSendBatch(command.pending) : undefined });
  } finally { core.destroy(); }
}
export function merge(json: string): string { return mergeDocumentUpdates(JSON.parse(json) as string[]); }
