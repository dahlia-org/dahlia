import { EventEmitter } from "node:events";
import type { Pool } from "pg";
import { afterEach, expect, it, vi } from "vitest";
import { PostgresSyncEvents } from "../src/sync/events-node";

afterEach(() => vi.useRealTimers());
it("falls back after LISTEN failure, coalesces both hint types and cleans up a disconnected listener", async () => {
  vi.useFakeTimers();
  const client = Object.assign(new EventEmitter(), { query: vi.fn().mockResolvedValue({}), release: vi.fn() });
  const pool = { connect: vi.fn().mockResolvedValueOnce(client).mockRejectedValue(new Error("offline")), query: vi.fn().mockRejectedValue(new Error("notify unavailable")) };
  const events = new PostgresSyncEvents(pool as unknown as Pool), abort = new AbortController();
  const watch = events.watch(["domain", "notes/workspace"], abort.signal);
  await vi.advanceTimersByTimeAsync(0);
  expect(events.pollInterval).toBe(5_000);
  watch.consume();
  client.emit("notification", { channel: "dahlia_sync_changed", payload: JSON.stringify(["domain", "notes/workspace", "notes/workspace"]) });
  expect(watch.consume()).toEqual(new Set(["domain", "notes/workspace"]));
  client.emit("error", new Error("connection lost"));
  await vi.advanceTimersByTimeAsync(0);
  expect(events.pollInterval).toBe(250);
  watch.consume(); let done = false;
  const pending = watch.wait().then(() => { done = true; });
  await vi.advanceTimersByTimeAsync(249); expect(done).toBe(false);
  await vi.advanceTimersByTimeAsync(1); await pending;
  events.publish("domain"); events.publish("notes/workspace");
  await vi.advanceTimersByTimeAsync(0); // Failed publishes never reject the committed save.
  expect(pool.query).toHaveBeenCalled();
  watch.close(); abort.abort(); await events.close();
  expect(client.release).toHaveBeenCalledExactlyOnceWith(true); expect(vi.getTimerCount()).toBe(0);
});
