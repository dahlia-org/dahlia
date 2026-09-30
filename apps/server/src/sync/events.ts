/** Hints only: every wake must reread and authorize the committed database state. */
export class SyncEvents {
  protected readonly listeners = new Map<string, Set<() => void>>();
  get pollInterval() { return 250; }
  subscribe(key: string, listener: () => void): () => void {
    let group = this.listeners.get(key);
    if (!group) { group = new Set(); this.listeners.set(key, group); }
    group.add(listener);
    return () => { group.delete(listener); if (!group.size) this.listeners.delete(key); };
  }
  publish(key: string): void { this.deliver(key); }
  protected deliver(key: string) { for (const listener of this.listeners.get(key) ?? []) listener(); }
  watch(key: string | string[], signal: AbortSignal) {
    const dirty = new Set<string>();
    let waiting: (() => void) | undefined;
    const wake = () => { waiting?.(); };
    const unsubscribe = (typeof key === "string" ? [key] : key).map((value) => this.subscribe(value, () => { dirty.add(value); wake(); }));
    signal.addEventListener("abort", wake);
    return {
      // Arm before reading: updates committed during the read must cause another read.
      consume: () => { const keys = new Set(dirty); dirty.clear(); return keys; },
      wait: (interval?: number) => new Promise<void>((resolve) => {
        if (dirty.size || signal.aborted) { resolve(); return; }
        const timer = setTimeout(done, interval ?? this.pollInterval);
        function done() { clearTimeout(timer); waiting = undefined; resolve(); }
        waiting = done;
      }),
      close: () => { unsubscribe.forEach((stop) => stop()); signal.removeEventListener("abort", wake); waiting?.(); },
    };
  }
}
export const documentEventKey = (workspaceId: string, documentId: string) => `${workspaceId}/${documentId}`;

export const notesEventKey = (workspaceId: string) => `notes/${workspaceId}`;
