import { DocumentCore, mergeDocumentUpdates, removedBlocks } from "./core";

import { documentSendBatch, type PendingDocumentUpdate } from "./transport";

interface Command {
  pending?: PendingDocumentUpdate[];
  checkpoint?: string;
  updates?: string[];
  text?: string;
  vector?: string;
  repair?: boolean;
}

/** JSON-only boundary: JSValue and Yjs objects never cross the owning JSC thread. */
export function run(json: string): string {
  const command = JSON.parse(json) as Command;
  const core = new DocumentCore(command.checkpoint);
  try {
    const before = core.projection();
    for (const update of command.updates ?? []) core.apply(update);
    if (command.text !== undefined) core.insertText(command.text, () => crypto.randomUUID());
    if (command.repair) core.repairBlockIDs(() => crypto.randomUUID());
    const projection = core.projection();
    return JSON.stringify({ checkpoint: core.checkpoint(), vector: core.vector(), projection,
      update: command.vector ? core.difference(command.vector) : core.checkpoint(),
      removed: removedBlocks(before, projection), batch: command.pending ? documentSendBatch(command.pending) : undefined });
  } finally { core.destroy(); }
}
export function merge(json: string): string { return mergeDocumentUpdates(JSON.parse(json) as string[]); }
