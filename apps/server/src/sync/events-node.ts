import type { Pool, PoolClient } from "pg";
import { SyncEvents } from "./events";

const channel = "dahlia_sync_changed";
/** One dedicated session per Node process. Workers/Hyperdrive use the shared-DB fallback. */
export class PostgresSyncEvents extends SyncEvents {
  private client: PoolClient | undefined;
  private connecting: Promise<void> | undefined;
  private retry: ReturnType<typeof setTimeout> | undefined;
  private stopped = false;
  private readonly pending = new Set<string>();
  private publishing: Promise<void> | undefined;
  private disconnect: (() => void) | undefined;
  constructor(private readonly pool: Pool) { super(); }
  override get pollInterval() { return this.client ? 5_000 : 250; }
  override subscribe(key: string, listener: () => void) {
    const unsubscribe = super.subscribe(key, listener);
    this.connect();
    return unsubscribe;
  }
  override publish(key: string) {
    super.publish(key);
    if (this.stopped) return;
    // Hints coalesce while the DB is busy. The HTTP fallback recovers any dropped hint.
    if (this.pending.size < 1_024) this.pending.add(key);
    this.startPublishing();
  }
  private startPublishing() {
    if (this.stopped || this.publishing || !this.pending.size) return;
    this.publishing = this.send().finally(() => { this.publishing = undefined; this.startPublishing(); });
  }
  private async send() {
    while (this.pending.size && !this.stopped) {
      const batch = [...this.pending].slice(0, 32);
      for (const key of batch) this.pending.delete(key);
      await this.pool.query("SELECT pg_notify($1, $2)", [channel, JSON.stringify(batch)]).catch(() => {});
    }
  }
  private connect() {
    if (this.stopped || this.client || this.connecting) return;
    this.connecting = this.listen().catch(() => {}).finally(() => {
      this.connecting = undefined;
      if (!this.stopped && !this.client && this.listeners.size) this.retry = setTimeout(() => this.connect(), 1_000);
    });
  }
  private async listen() {
    const client = await this.pool.connect();
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      if (this.client === client) this.client = undefined;
      if (this.disconnect === release) this.disconnect = undefined;
      client.release(true);
      if (!this.stopped) { for (const key of this.listeners.keys()) this.deliver(key); this.connect(); }
    };
    this.disconnect = release;
    client.on("error", release);
    client.on("end", release);
    client.on("notification", (message) => {
      if (message.channel !== channel || !message.payload) return;
      try {
        const keys: unknown = JSON.parse(message.payload);
        if (Array.isArray(keys)) for (const key of keys) if (typeof key === "string") this.deliver(key);
      } catch { /* A hint never supplies canonical state. */ }
    });
    try {
      await client.query(`LISTEN ${channel}`);
      if (this.stopped || released) { release(); return; }
      this.client = client;
      // LISTEN is now active; close the initial subscription race by rereading.
      for (const key of this.listeners.keys()) this.deliver(key);
    } catch { release(); }
  }
  async close() {
    this.stopped = true;
    clearTimeout(this.retry);
    await this.connecting;
    await this.publishing;
    this.disconnect?.();
  }
}
