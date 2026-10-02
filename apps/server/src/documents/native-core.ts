import { DocumentCore, mergeDocumentUpdates, removedBlocks, type DocumentBlock } from "./core";
import { documentSendBatch, type PendingDocumentUpdate } from "./transport";

interface Command {
  pending?: PendingDocumentUpdate[];
  checkpoint?: string;
  updates?: string[];
  text?: string;
  vector?: string;
  purgeBefore?: number;
  local?: boolean;
  lightweight?: boolean;
  sending?: boolean;
  runtime?: { key: string; baseline: string; entries: PendingDocumentUpdate[]; after?: number; prerequisites?: string[]; recoveryThrough?: number; draft?: string; action?: "commit" | "rollback" };
}
interface Runtime { core: DocumentCore; staged: DocumentCore; baseline: string; through: number; draft?: string; touched: number; recoveries: Map<number, DocumentBlock[]> }
const runtimes = new Map<string, Runtime>();
function release(runtime: Runtime) { runtime.core.destroy(); runtime.staged.destroy(); }

/** JSON-only boundary: persistent Yjs replicas never cross the owning JSC thread. */
export function run(json: string): string {
  const command = JSON.parse(json) as Command;
  const request = command.runtime;
  let runtime: Runtime | undefined;
  let core: DocumentCore;
  const removed: DocumentBlock[] = [];
  let changed = false;
  let previous: ReturnType<DocumentCore["constraints"]> | undefined;
  try {
  if (request) {
    for (const [key, cached] of runtimes) if (key !== request.key && Date.now() - cached.touched > 300_000) { release(cached); runtimes.delete(key); }
    runtime = runtimes.get(request.key);
    if (!runtime && runtimes.size >= 16) { const oldest = [...runtimes].sort((a, b) => a[1].touched - b[1].touched)[0]!; release(oldest[1]); runtimes.delete(oldest[0]); }
    if (!runtime && !command.checkpoint) throw new Error("document_runtime_unavailable");
    if (!runtime || runtime.baseline !== request.baseline || command.checkpoint !== undefined) {
      if (runtime) release(runtime);
      runtime = { core: new DocumentCore(command.checkpoint), staged: new DocumentCore(command.checkpoint), baseline: request.baseline, through: Number(request.baseline.split("/")[0]), touched: Date.now(), recoveries: new Map() };
      runtimes.set(request.key, runtime);
    }
    runtime.touched = Date.now();
    if (runtime.through < (request.after ?? 0)) throw new Error("document_runtime_unavailable");
    if (request.action === "rollback" || (runtime.draft && request.action !== "commit")) {
      runtime.staged.destroy(); runtime.staged = new DocumentCore(runtime.core.checkpoint(false)); runtime.draft = undefined;
    }
    for (const entry of request.entries) if (entry.sequence > runtime.through) {
      const recovered = runtime.core.apply(entry.update);
      if (recovered.length) runtime.recoveries.set(entry.sequence, recovered);
      runtime.staged.apply(entry.update); runtime.through = entry.sequence;
    }
    for (const [sequence, blocks] of runtime.recoveries) {
      if (sequence <= (request.recoveryThrough ?? 0)) runtime.recoveries.delete(sequence);
      else removed.push(...blocks);
    }
    if (request.action === "commit") {
      for (const update of request.prerequisites ?? []) runtime.core.apply(update);
      if (request.draft) runtime.core.apply(request.draft);
      if (runtime.draft !== request.draft) { runtime.staged.destroy(); runtime.staged = new DocumentCore(runtime.core.checkpoint(false)); }
      runtime.draft = undefined; core = runtime.core;
    } else if (request.draft) {
      previous = runtime.staged.constraints();
      for (const update of request.prerequisites ?? []) removed.push(...runtime.staged.apply(update));
      const version = runtime.staged.changeVersion;
      removed.push(...runtime.staged.apply(request.draft)); changed = runtime.staged.changeVersion !== version; runtime.draft = request.draft; core = runtime.staged;
    } else core = runtime.core;
  } else core = new DocumentCore(command.checkpoint);
    if (!request) {
      const before = core.projection(false);
      for (const update of command.updates ?? []) core.apply(update);
      if (command.text !== undefined) core.insertText(command.text, () => crypto.randomUUID());
      removed.push(...removedBlocks(before, core.projection(false)));
    }
    const purged = command.purgeBefore !== undefined && core.purgeDeletedBlocks(command.purgeBefore) > 0;
    if (command.local) core.validate(previous);
    const projection = command.lightweight ? { text: "", blocks: [] } : core.projection(command.local === true);
    const checkpoint = command.lightweight ? "" : core.checkpoint(command.local === true);
    return JSON.stringify({ checkpoint, vector: core.vector(), projection,
      update: command.vector || command.sending ? core.difference(command.vector) : checkpoint,
      removed, purged, changed, runtimeThrough: runtime?.through, diagnostics: core.diagnostics,
      batch: command.pending ? documentSendBatch(command.pending) : undefined });
  } catch (error) {
    if (request && runtime) { release(runtime); runtimes.delete(request.key); }
    throw error;
  } finally { if (!request && core!) core.destroy(); }
}
export function merge(json: string): string { return mergeDocumentUpdates(JSON.parse(json) as string[]); }
