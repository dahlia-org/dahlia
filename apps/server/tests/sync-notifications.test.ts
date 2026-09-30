import { afterEach, expect, it, vi } from "vitest";
import { SyncNotifications } from "../src/client/sync-notifications";

class Source extends EventTarget {
  static instances: Source[] = [];
  closed = false;
  constructor(readonly url: string) { super(); Source.instances.push(this); }
  close() { this.closed = true; }
  hint(meetingId: string, unavailable = false) {
    this.dispatchEvent(new MessageEvent("document", { data: JSON.stringify({ workspaceId: "workspace", meetingId, documentId: "doc", cursor: "generation:2", unavailable }) }));
  }
}
function setup() {
  vi.useFakeTimers(); Source.instances = []; vi.stubGlobal("EventSource", Source);
  return new SyncNotifications();
}
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });
it("shares one connection, refcounts views, removes closed Notes and ignores late events", async () => {
  const tab = setup(), domain = vi.fn(), first = vi.fn(), second = vi.fn(), other = vi.fn();
  const stopDomain = tab.subscribeDomain("user", domain);
  const stopFirst = tab.subscribeNotes("user", "workspace", "meeting", first);
  const stopSecond = tab.subscribeNotes("user", "workspace", "meeting", second);
  const stopOther = tab.subscribeNotes("user", "workspace", "other", other);
  await vi.advanceTimersByTimeAsync(0);
  expect(Source.instances).toHaveLength(1);
  const source = Source.instances[0]!;
  const query = new URL(source.url, "http://localhost").searchParams;
  expect(JSON.parse(query.get("notes")!)).toHaveLength(2);
  source.dispatchEvent(new Event("open"));
  expect(domain).toHaveBeenCalledWith(true); expect(first).toHaveBeenCalledOnce();
  first.mockClear(); second.mockClear(); other.mockClear();
  stopFirst(); source.hint("meeting");
  expect(first).not.toHaveBeenCalled(); expect(second).toHaveBeenCalledOnce(); expect(source.closed).toBe(false);
  stopSecond(); expect(source.closed).toBe(true);
  source.hint("other"); expect(other).not.toHaveBeenCalled();
  await vi.advanceTimersByTimeAsync(0);
  const replacement = Source.instances[1]!;
  expect(JSON.parse(new URL(replacement.url, "http://localhost").searchParams.get("notes")!)).toEqual([{ workspaceId: "workspace", meetingId: "other" }]);
  replacement.dispatchEvent(new Event("open")); expect(other).toHaveBeenCalledOnce();
  replacement.hint("meeting"); expect(second).toHaveBeenCalledOnce();
  replacement.hint("other", true); expect(other).toHaveBeenLastCalledWith(expect.objectContaining({ unavailable: true }));
  stopOther(); stopDomain(); expect(vi.getTimerCount()).toBe(0);
});
it("isolates tabs and account generations and reads again on reconnect", async () => {
  const first = setup(), second = new SyncNotifications();
  const firstRead = vi.fn(), secondRead = vi.fn();
  const stopFirst = first.subscribeNotes("old", "workspace", "meeting", firstRead);
  const stopSecond = second.subscribeNotes("old", "workspace", "meeting", secondRead);
  await vi.advanceTimersByTimeAsync(0);
  const [one, two] = Source.instances;
  expect(new URL(one!.url, "http://localhost").searchParams.get("tab")).not.toBe(new URL(two!.url, "http://localhost").searchParams.get("tab"));
  one!.dispatchEvent(new Event("open")); one!.dispatchEvent(new Event("error")); expect(first.connected).toBe(false);
  one!.dispatchEvent(new Event("open")); expect(firstRead).toHaveBeenCalledTimes(2); expect(secondRead).not.toHaveBeenCalled();
  const stopDomain = first.subscribeDomain("new", () => {});
  const current = vi.fn(), stopCurrent = first.subscribeNotes("new", "workspace", "meeting", current);
  expect(one!.closed).toBe(true); expect(two!.closed).toBe(false);
  one!.hint("meeting"); expect(current).not.toHaveBeenCalled();
  stopFirst(); await vi.advanceTimersByTimeAsync(0);
  const latest = Source.instances.at(-1)!;
  expect(new URL(latest.url, "http://localhost").searchParams.get("user")).toBe("new");
  latest.dispatchEvent(new Event("open")); expect(current).toHaveBeenCalledOnce();
  stopCurrent(); stopDomain(); expect(two!.closed).toBe(false); stopSecond(); expect(vi.getTimerCount()).toBe(0);
});

it("preserves active account listeners against stale Notes consumers and allows idle reuse", async () => {
  const tab = setup(), domain = vi.fn(), note = vi.fn();
  const stopDomain = tab.subscribeDomain("current", domain);
  const stopNote = tab.subscribeNotes("current", "workspace", "meeting", note);
  await vi.advanceTimersByTimeAsync(0);
  const source = Source.instances.at(-1)!;
  expect(() => tab.subscribeNotes("old", "workspace", "meeting", () => {})).toThrow();
  expect(source.closed).toBe(false);
  source.dispatchEvent(new Event("invalidation")); source.hint("meeting");
  expect(domain).toHaveBeenCalledWith(false); expect(note).toHaveBeenCalledOnce();
  stopDomain();
  expect(() => tab.subscribeNotes("old", "workspace", "meeting", () => {})).toThrow();
  stopNote();
  const stopReused = tab.subscribeNotes("other", "workspace", "meeting", () => {});
  await vi.advanceTimersByTimeAsync(0);
  expect(new URL(Source.instances.at(-1)!.url, "http://localhost").searchParams.get("user")).toBe("other");
  stopReused(); expect(vi.getTimerCount()).toBe(0);
});
