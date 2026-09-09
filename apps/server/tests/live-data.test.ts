import { afterEach, expect, it, vi } from "vitest";
import { accountSettingsEvent, inaccessible, liveDataEvent, readVisiblePages, refreshQueue, retainEqual, subscribeLiveUpdates } from "../src/client/live-data";
import { RequestError } from "../src/client/api";
import { dashboardNavigationEvent, dashboardNavigationPath, navigateDashboard } from "../src/client/navigation";

afterEach(() => vi.unstubAllGlobals());

it("coalesces a burst into one trailing read and aborts when the consumer changes", async () => {
  let resolveFirst!: () => void;
  const first = { promise: new Promise<void>((resolve) => { resolveFirst = resolve; }), resolve: () => resolveFirst() };
  const signals: AbortSignal[] = [];
  const read = vi.fn(async (signal: AbortSignal) => {
    signals.push(signal);
    if (signals.length === 1) await first.promise;
  });
  const queue = refreshQueue(read);
  const initial = queue.refresh();
  for (let index = 0; index < 20; index++) await queue.refresh();
  expect(read).toHaveBeenCalledTimes(1);
  first.resolve();
  await initial;
  expect(read).toHaveBeenCalledTimes(2);
  queue.dispose();
  expect(signals.every((signal) => signal.aborted)).toBe(true);
  await queue.refresh();
  expect(read).toHaveBeenCalledTimes(2);
});

it("does not run a queued refresh after disposal", async () => {
  let resolvePending!: () => void;
  const pending = { promise: new Promise<void>((resolve) => { resolvePending = resolve; }), resolve: () => resolvePending() };
  const read = vi.fn(() => pending.promise);
  const queue = refreshQueue(read);
  const first = queue.refresh();
  await queue.refresh();
  queue.dispose();
  pending.resolve();
  await first;
  expect(read).toHaveBeenCalledTimes(1);
});

it("retains unchanged objects across inserts, edits, deletions and reordering", () => {
  const previous = { items: [{ id: "a", text: "A" }, { id: "b", text: "B" }], nextCursor: "b" };
  expect(retainEqual(previous, structuredClone(previous))).toBe(previous);
  const next = retainEqual(previous, { items: [{ id: "c", text: "C" }, { id: "b", text: "B" }, { id: "a", text: "Edited" }], nextCursor: "a" });
  expect(next.items[1]).toBe(previous.items[1]);
  expect(next.items[2]?.text).toBe("Edited");
  expect(retainEqual(next, { items: [{ id: "b", text: "B" }], nextCursor: "" }).items[0]).toBe(previous.items[1]);
});

it("rebuilds the visible range from fresh cursors, preserving filters and the next page", async () => {
  const fetch = vi.fn((url: string) => {
    const parsed = new URL(url, "http://localhost");
    expect(parsed.searchParams.get("q")).toBe("meeting");
    return Promise.resolve(Response.json(parsed.searchParams.has("cursor")
      ? { items: [{ id: "b" }, { id: "c" }], nextCursor: "c" }
      : { items: [{ id: "new" }, { id: "a" }], nextCursor: "a" }));
  });
  vi.stubGlobal("fetch", fetch);
  const result = await readVisiblePages("/api/meetings?q=meeting", 3, new AbortController().signal);
  expect(result).toEqual({ items: [{ id: "new" }, { id: "a" }, { id: "b" }, { id: "c" }], nextCursor: "c" });
  expect(fetch.mock.calls.map(([url]) => url)).toEqual(["/api/meetings?q=meeting", "/api/meetings?q=meeting&cursor=a"]);
});

it("stops on the last page after deletions and discards aborted page responses", async () => {
  vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(Response.json({ items: [{ id: "remaining" }], nextCursor: null }))));
  expect((await readVisiblePages("/api/meetings", 400, new AbortController().signal)).items).toHaveLength(1);
  const controller = new AbortController();
  vi.stubGlobal("fetch", vi.fn(() => { controller.abort(); return Promise.resolve(Response.json({ items: [{ id: "stale" }] })); }));
  await expect(readVisiblePages("/api/meetings", 1, controller.signal)).rejects.toMatchObject({ name: "AbortError" });
});

it("invalidates on connection, reconnection and notifications without persisting a data checkpoint", () => {
  const browser = new EventTarget();
  vi.stubGlobal("window", browser);
  const changed = vi.fn();
  const settingsChanged = vi.fn();
  browser.addEventListener(accountSettingsEvent, settingsChanged);
  browser.addEventListener(liveDataEvent, changed);
  const source = new EventTarget();
  const close = vi.fn();
  vi.stubGlobal("EventSource", class { constructor(url: string) { expect(url).toBe("/api/v1/events"); return Object.assign(source, { close }); } });
  const dispose = subscribeLiveUpdates();
  source.dispatchEvent(new Event("open"));
  source.dispatchEvent(new Event("invalidation"));
  source.dispatchEvent(new Event("open"));
  expect(changed).toHaveBeenCalledTimes(3);
  expect(settingsChanged).toHaveBeenCalledTimes(2);
  source.dispatchEvent(new Event("account_settings"));
  expect(settingsChanged).toHaveBeenCalledTimes(3);
  expect(changed).toHaveBeenCalledTimes(3);
  dispose();
  expect(close).toHaveBeenCalledOnce();
});

it("distinguishes revoked/deleted data from transient refresh failures", () => {
  for (const status of [401, 403, 404]) expect(inaccessible(new RequestError("denied", status))).toBe(true);
  for (const status of [409, 429, 500, 503]) expect(inaccessible(new RequestError("retry", status))).toBe(false);
  expect(inaccessible(new TypeError("offline"))).toBe(false);
});

it("navigates within browser history and allows explicitly registered extension paths", () => {
  const browser = Object.assign(new EventTarget(), { location: { pathname: "/vaults" }, history: { pushState: vi.fn(), replaceState: vi.fn() } });
  vi.stubGlobal("window", browser);
  vi.stubGlobal("PopStateEvent", Event);
  const changed = vi.fn();
  browser.addEventListener("popstate", changed);
  const navigated = vi.fn();
  browser.addEventListener(dashboardNavigationEvent, navigated);
  navigateDashboard("/vaults");
  expect(navigated).toHaveBeenCalledOnce();
  expect(changed).not.toHaveBeenCalled();
  expect(browser.history.pushState).not.toHaveBeenCalled();
  expect(browser.history.replaceState).not.toHaveBeenCalled();
  navigateDashboard("/organizations");
  expect(browser.history.pushState).toHaveBeenCalledWith(null, "", "/organizations");
  navigateDashboard("/dashboard", true);
  expect(browser.history.replaceState).toHaveBeenCalledWith(null, "", "/dashboard");
  expect(changed).toHaveBeenCalledTimes(2);
  expect(navigated).toHaveBeenCalledTimes(3);
  expect(dashboardNavigationPath("/custom", "https://dahlia.test", ["/custom"])).toBe("/custom");
  expect(dashboardNavigationPath("https://elsewhere.test/custom", "https://dahlia.test", ["/custom"])).toBeUndefined();
});
