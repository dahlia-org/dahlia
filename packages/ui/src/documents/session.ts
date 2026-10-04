import { DocumentCore, documentUpdateLimit, type DocumentRecovery } from "./core";

export interface DocumentExchange {
  generation: string | null;
  revision: number;
  update: string;
  /** An authorized canonical reread after generation conflict; this does not acknowledge the rejected batch. */
  refreshed?: boolean;
  accepted?: boolean;
  reason?: "document_too_large";
  vector?: string;
}
export type { PendingDocumentUpdate } from "./transport";
import { documentReplyVersion, type PendingDocumentUpdate } from "./transport";
export interface DocumentHost {
  newID(): string;
  // Restart from committed state, excluding editor drafts whose append has not succeeded.
  snapshot?(): string;
  // Append and recovery preservation must be one local transaction. Resolve only after commit.
  append(update: string, local: boolean, recovery: DocumentRecovery | null): Promise<number>;
  pending(): Promise<PendingDocumentUpdate[]>;
  acknowledge(through: number): Promise<void>;
  exchange(request: { generation: string | null; vector: string; update?: string }): Promise<DocumentExchange>;
  checkpoint(state: { update: string; vector: string; through: number; revision: number; generation: string | null }): Promise<void>;
}

/** The same ordered durability boundary works with SQLite and a volatile browser adapter. */
export class DocumentSession {
  readonly core: DocumentCore;
  generation: string | null;
  revision: number;
  private tail: Promise<void> = Promise.resolve();
  private preview: DocumentCore;
  private serverVector?: string;
  private rejected?: string;
  private sending: Promise<void> | null = null;
  constructor(private readonly host: DocumentHost, initial?: { checkpoint?: string; generation: string | null; revision: number }) {
    this.core = new DocumentCore(initial?.checkpoint);
    this.preview = new DocumentCore(initial?.checkpoint);
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
      try {
        const previous = this.preview.constraints();
        const blocks = this.preview.apply(update);
        if (local) this.preview.validate(previous);
        const recovery: DocumentRecovery | null = blocks.length && (local || (await this.host.pending()).length)
          ? { id: this.host.newID(), blocks, reason: local ? "deleted" : "concurrent_delete" } : null;
        const sequence = await this.host.append(update, local, recovery);
        this.core.apply(update);
        this.generation = version.generation;
        this.revision = version.revision;
        await this.host.checkpoint({ update, vector: this.core.vector(), through: sequence, revision: this.revision, generation: this.generation });
      } catch (error) {
        this.preview.destroy(); this.preview = new DocumentCore(this.core.checkpoint(false));
        throw error;
      }
    });
  }
  /** Network failures leave the durable outbox intact. A received update is merged even while pending. */
  synchronize(): Promise<void> {
    if (this.sending) return this.sending;
    this.sending = this.exchange().finally(() => { this.sending = null; });
    return this.sending;
  }
  private async exchange(): Promise<void> {
    const captured = await this.ordered(async () => {
      const pending = await this.host.pending();
      const through = pending.at(-1)?.sequence ?? null;
      const key = `${through}/${this.generation}/${this.revision}`;
      return { through, key, vector: this.core.vector(), generation: this.generation,
        update: through !== null && key !== this.rejected ? this.core.difference(this.serverVector) : undefined };
    });
    const oversized = captured.update !== undefined && captured.update.length > Math.ceil(documentUpdateLimit / 3) * 4;
    if (oversized) captured.update = undefined;
    const response = await this.host.exchange({ generation: captured.generation, vector: captured.vector,
      ...(captured.update ? { update: captured.update } : {}) });
    await this.accept(response.update, false, response);
    this.serverVector = response.vector;
    if (response.accepted === false || oversized) this.rejected = `${captured.through}/${this.generation}/${this.revision}`;
    else if (!response.refreshed && captured.update && captured.through !== null) {
      await this.ordered(() => this.host.acknowledge(captured.through!)); this.rejected = undefined;
    }
    if (response.accepted === false || oversized || (captured.through !== null && captured.key === this.rejected)) throw new Error("document_too_large");
  }
  async flush(): Promise<void> {
    do { await this.synchronize(); await this.tail; } while ((await this.host.pending()).length);
  }
  async close(): Promise<void> { await this.tail; this.core.destroy(); this.preview.destroy(); }
}
