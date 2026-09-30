import { afterEach, expect, it, vi } from "vitest";
import { SyncEvents } from "../src/sync/events";

afterEach(() => vi.useRealTimers());
it("does not lose invalidations during a database read and disposes a sleeping subscriber", async () => {
  vi.useFakeTimers();
  const events = new SyncEvents(), abort = new AbortController();
  const watch = events.watch("workspace/document", abort.signal);
  watch.consume(); events.publish("workspace/document");
  await watch.wait(); // Already dirty: must not wait for the fallback timer.
  watch.consume();
  let woke = false;
  const waiting = watch.wait().then(() => { woke = true; });
  events.publish("other/document"); await Promise.resolve(); expect(woke).toBe(false);
  abort.abort(); await waiting; expect(woke).toBe(true);
  watch.close(); expect(vi.getTimerCount()).toBe(0);
});
it("keeps a bounded shared-database fallback when another instance cannot push", async () => {
  vi.useFakeTimers();
  const events = new SyncEvents(), watch = events.watch("workspace/document", new AbortController().signal);
  watch.consume(); let woke = false;
  const waiting = watch.wait().then(() => { woke = true; });
  await vi.advanceTimersByTimeAsync(249); expect(woke).toBe(false);
  await vi.advanceTimersByTimeAsync(1); await waiting; expect(woke).toBe(true);
  watch.close(); expect(vi.getTimerCount()).toBe(0);
});
