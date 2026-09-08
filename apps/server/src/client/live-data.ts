import { useEffect, useEffectEvent, useRef, useState } from "react";
import { clientMutationEvent, json, RequestError } from "./api";

export const accountSettingsEvent = "dahlia:account-settings-changed";
export const liveDataEvent = "dahlia:data-changed";
export const refreshData = () => window.dispatchEvent(new Event(liveDataEvent));

// One active read and one trailing read, regardless of the notification burst size.
export function refreshQueue(read: (signal: AbortSignal) => Promise<void>) {
  const controller = new AbortController();
  let running = false;
  let dirty = false;
  const refresh = async () => {
    if (controller.signal.aborted) return;
    dirty = true;
    if (running) return;
    running = true;
    try {
      while (dirty && !controller.signal.aborted) {
        dirty = false;
        await read(controller.signal);
      }
    } finally { running = false; }
  };
  return { refresh, dispose: () => controller.abort() };
}

export function inaccessible(error: unknown) {
  return error instanceof RequestError && [401, 403, 404].includes(error.status ?? 0);
}

export function retainEqual<T>(previous: T | undefined, next: T): T {
  if (JSON.stringify(previous) === JSON.stringify(next)) return previous as T;
  if (Array.isArray(previous) && Array.isArray(next)) {
    const identity = (value: unknown, index: number) => {
      if (value && typeof value === "object") {
        const row = value as Record<string, unknown>;
        return row.id ?? row.meetingId ?? row.projectId ?? row.vaultId ?? row.segmentId ?? index;
      }
      return index;
    };
    const old = new Map<unknown, unknown>(previous.map((value: unknown, index) => [identity(value, index), value]));
    return next.map((value: unknown, index) => retainEqual(old.get(identity(value, index)), value)) as T;
  }
  if (previous && next && typeof previous === "object" && typeof next === "object" && !Array.isArray(next)) {
    return Object.fromEntries(Object.entries(next).map(([key, value]) =>
      [key, retainEqual((previous as Record<string, unknown>)[key], value)])) as T;
  }
  return next;
}

export function useLiveQuery<T>(key: string | undefined, load: (signal: AbortSignal, previous?: T) => Promise<T>, scope: "all" | "account" | "manual" = "all") {
  const [state, setState] = useState<{ key?: string; data?: T; error?: Error; loading: boolean }>({ loading: true });
  const queue = useRef<ReturnType<typeof refreshQueue> | null>(null);
  const read = useEffectEvent(load);
  const apply = useRef<((next: T) => void) | null>(null);
  useEffect(() => {
    if (key === undefined) return;
    let data: T | undefined;
    let generation = 0;
    apply.current = (next) => {
      generation++;
      data = retainEqual(data, next);
      setState({ key, data, loading: false });
    };
    const current = refreshQueue(async (signal) => {
      const requestGeneration = generation;
      setState((state) => ({ ...state, loading: true }));
      try {
        const next = await read(signal, data);
        if (signal.aborted || requestGeneration !== generation) return;
        data = retainEqual(data, next);
        setState({ key, data, loading: false });
      } catch (caught) {
        if (signal.aborted || requestGeneration !== generation) return;
        if (inaccessible(caught)) data = undefined;
        setState({ key, data, error: caught instanceof Error ? caught : new Error("Could not load data"), loading: false });
      }
    });
    queue.current = current;
    const refresh = () => { void current.refresh(); };
    const events: string[] = [];
    if (scope === "all") events.push(liveDataEvent, clientMutationEvent);
    else if (scope === "account") events.push(accountSettingsEvent);
    for (const event of events) window.addEventListener(event, refresh);
    if (scope !== "manual") window.addEventListener("online", refresh);
    refresh();
    return () => {
      current.dispose();
      queue.current = null;
      apply.current = null;
      for (const event of events) window.removeEventListener(event, refresh);
      if (scope !== "manual") window.removeEventListener("online", refresh);
    };
  }, [key, scope]);
  const isCurrent = key !== undefined && state.key === key;
  return {
    data: isCurrent ? state.data : undefined,
    error: isCurrent ? state.error : undefined,
    loading: key !== undefined && (!isCurrent || state.loading),
    reload: () => { void queue.current?.refresh(); },
    replace: (next: T) => apply.current?.(next),
  };
}

export function useLiveJSON<T>(url?: string, scope: "all" | "account" | "manual" = "all") {
  return useLiveQuery<T>(url, (signal) => json<T>(url!, { signal }), scope);
}

export interface Page<T> { items: T[]; nextCursor?: string | null }

export async function readVisiblePages<T>(url: string, minimum: number, signal: AbortSignal): Promise<Page<T>> {
  const items: T[] = [];
  let cursor: string | null | undefined;
  do {
    const next = new URL(url, "http://localhost");
    if (cursor) next.searchParams.set("cursor", cursor);
    const page = await json<Page<T>>(`${next.pathname}${next.search}`, { signal });
    signal.throwIfAborted();
    items.push(...page.items);
    cursor = page.nextCursor;
  } while (cursor && items.length < minimum);
  return { items, nextCursor: cursor };
}

export function useLivePage<T>(url: string) {
  const demand = useRef({ url, count: 1 });
  useEffect(() => { demand.current = { url, count: 1 }; }, [url]);
  const query = useLiveQuery<Page<T>>(url, (signal, previous) => {
    const requestedCount = demand.current.url === url ? demand.current.count : 1;
    const visibleCount = Math.max(previous?.items.length ?? 1, requestedCount);
    return readVisiblePages<T>(url, visibleCount, signal);
  });
  const loadingMore = query.loading && demand.current.url === url && demand.current.count > (query.data?.items.length ?? 0);
  const loadMore = () => {
    if (!query.data?.nextCursor) return;
    demand.current = { url, count: query.data.items.length + 1 };
    query.reload();
  };
  return { ...query, loadingMore, loadMore };
}

export function subscribeLiveUpdates() {
  // EventSource owns reconnect cursors. A notification is never a completed data checkpoint.
  const source = new EventSource("/api/v1/events");
  const refreshSettings = () => window.dispatchEvent(new Event(accountSettingsEvent));
  source.addEventListener("open", refreshData);
  source.addEventListener("open", refreshSettings);
  source.addEventListener("account_settings", refreshSettings);
  source.addEventListener("invalidation", refreshData);
  return () => source.close();
}
