import { setTimeout as delay } from "node:timers/promises";

import type { SearchEmbedder } from "./embedding";
import { SearchEmbeddingError } from "./embedding";
import { processSearchIndexBatch } from "./process";
export { processSearchIndexBatch } from "./process";
import type { SearchIndexStore } from "./index-store";

const RECONCILE_INTERVAL_MS = 60_000;

export class SearchIndexer {
  private stopping = false;
  private running?: Promise<void>;
  private readonly abort = new AbortController();

  constructor(
    private readonly store: SearchIndexStore,
    private readonly embedder: SearchEmbedder,
  ) {}

  start(): void {
    this.running ??= this.run();
  }

  async stop(): Promise<void> {
    this.stopping = true;
    this.abort.abort();
    if (this.running) await this.running;
  }

  private async run(): Promise<void> {
    let nextReconcileAt = 0;
    const reconcile = async () => {
      try {
        await this.store.reconcile(this.embedder.model, this.embedder.dimensions);
      } catch (error) {
        this.log("search_index_reconcile_failed", error);
      }
      nextReconcileAt = Date.now() + RECONCILE_INTERVAL_MS;
    };
    await reconcile();
    while (!this.stopping) {
      try {
        if (Date.now() >= nextReconcileAt) await reconcile();
        if (await processSearchIndexBatch(this.store, this.embedder, this.abort.signal) > 0) continue;
      } catch (error) {
        this.log("search_index_batch_failed", error);
      }
      await delay(1_000, undefined, { ref: false });
    }
  }

  private log(event: string, error: unknown): void {
    console.warn(JSON.stringify({
      level: "warn",
      event,
      errorName: error instanceof Error ? error.name : "UnknownError",
      errorCode: error instanceof SearchEmbeddingError ? error.code : undefined,
    }));
  }
}
