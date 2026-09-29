import { DocumentCore, removedBlocks, type DocumentProjection, type DocumentRecovery } from "./core";

export interface DocumentExchange {
  generation: string | null;
  revision: number;
  update: string;
  /** An authorized canonical reread after generation conflict; this does not acknowledge the rejected batch. */
  refreshed?: boolean;
}
export type { PendingDocumentUpdate } from "./transport";
import { documentSendBatch, documentReplyVersion, type PendingDocumentUpdate } from "./transport";
export interface DocumentHost {
  newID(): string;
  // Append and recovery preservation must be one local transaction. Resolve only after commit.
  append(update: string, local: boolean, recovery: DocumentRecovery | null): Promise<number>;
  pending(): Promise<PendingDocumentUpdate[]>;
  acknowledge(through: number): Promise<void>;
  exchange(request: { generation: string | null; vector: string; update?: string }): Promise<DocumentExchange>;
  checkpoint(state: { checkpoint: string; projection: DocumentProjection; through: number; revision: number; generation: string | null }): Promise<void>;
}

/** The same ordered durability boundary works with SQLite and a volatile browser adapter. */
export class DocumentSession {
  readonly core: DocumentCore;
  generation: string | null;
  revision: number;
  private hasLocalEdits = false;
  private tail: Promise<void> = Promise.resolve();
  private sending: Promise<void> | null = null;
  constructor(private readonly host: DocumentHost, initial?: { checkpoint?: string; generation: string | null; revision: number }) {
    this.core = new DocumentCore(initial?.checkpoint);
    this.generation = initial?.generation ?? null;
    this.revision = initial?.revision ?? 0;
  }
  private ordered<T>(work: () => Promise<T>): Promise<T> {
    const result = this.tail.then(work);
    // One rejected save must not permanently wedge subsequent recovery or retries.
    this.tail = result.then(() => {}, () => {});
    return result;
  }
  accept(update: string, local: boolean, incoming?: Pick<DocumentExchange, "generation" | "revision" | "refreshed">): Promise<void> {
    return this.ordered(async () => {
      const version = incoming?.refreshed ? { generation: incoming.generation, revision: incoming.revision }
        : incoming ? documentReplyVersion(this, incoming) : { generation: this.generation, revision: this.revision };
      const preview = new DocumentCore(this.core.checkpoint());
      try {
        const before = preview.projection();
        preview.apply(update);
        const projection = preview.projection();
        const blocks = removedBlocks(before, projection);
        const recovery: DocumentRecovery | null = !local && this.hasLocalEdits && blocks.length
          ? { id: this.host.newID(), blocks, reason: "concurrent_delete" } : null;
        const sequence = await this.host.append(update, local, recovery);
        this.core.apply(update);
        if (local) this.hasLocalEdits = true;
        this.generation = version.generation;
        this.revision = version.revision;
        await this.host.checkpoint({ checkpoint: this.core.checkpoint(), projection, through: sequence,
          revision: this.revision, generation: this.generation });
      } finally { preview.destroy(); }
    });
  }
  /** Network failures leave the durable outbox intact. A received update is merged even while pending. */
  synchronize(): Promise<void> {
    if (this.sending) return this.sending;
    this.sending = this.exchange().finally(() => { this.sending = null; });
    return this.sending;
  }
  private async exchange(): Promise<void> {
    await this.tail;
    const pending = await this.host.pending();
    const batch = documentSendBatch(pending);
    const response = await this.host.exchange({ generation: this.generation, vector: this.core.vector(),
      ...(batch.update ? { update: batch.update } : {}) });
    await this.accept(response.update, false, response);
    if (!response.refreshed && batch.through !== null) await this.host.acknowledge(batch.through);
  }
  async flush(): Promise<void> {
    do { await this.synchronize(); await this.tail; } while ((await this.host.pending()).length);
  }
  async close(): Promise<void> { await this.tail; this.core.destroy(); }
}
