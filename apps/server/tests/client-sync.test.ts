import { afterEach, expect, it, vi } from "vitest";
import { commitSyncTransaction, syncMessage } from "../src/client/App";

afterEach(() => vi.unstubAllGlobals());

it("resolves a lost response as a compact receipt without another mutation", async () => {
  const bodies: string[] = [];
  const fetch = vi.fn(async (_url: string, init: RequestInit) => {
    const body = String(init.body);
    bodies.push(body);
    if (bodies.length === 1) throw new TypeError("connection lost");
    const transaction = JSON.parse(body) as { id: string };
    return Response.json({ id: transaction.id, status: "committed", receipt: "compact", records: [] });
  });
  vi.stubGlobal("fetch", fetch);
  const progress = vi.fn();
  expect(await commitSyncTransaction(crypto.randomUUID(), [], progress)).toMatchObject({ receipt: "compact" });
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(fetch.mock.calls[1]?.[0]).toBe("/api/v1/transactions/resolve");
  expect(bodies[0]).toBe(bodies[1]);
  expect(progress.mock.calls).toEqual([[true], [false]]);
});

it("retains the transaction ID when resolution reports an uncommitted request", async () => {
  const bodies: string[] = [];
  vi.stubGlobal("fetch", vi.fn(async (_url: string, init: RequestInit) => {
    bodies.push(String(init.body));
    if (bodies.length === 1) return Response.json({ error: "unavailable" }, { status: 503 });
    const { id } = JSON.parse(String(init.body)) as { id: string };
    return Response.json({ id, status: bodies.length === 2 ? "unknown" : "committed" });
  }));
  await commitSyncTransaction(crypto.randomUUID(), []);
  expect(bodies).toHaveLength(3);
  expect(new Set(bodies).size).toBe(1);
});

it("does not retry revision conflicts and provides English and Japanese recovery messages", async () => {
  const fetch = vi.fn(async () => Response.json({ error: "revision_conflict" }, { status: 409 }));
  vi.stubGlobal("fetch", fetch);
  await expect(commitSyncTransaction(crypto.randomUUID(), [])).rejects.toMatchObject({ status: 409 });
  expect(fetch).toHaveBeenCalledTimes(1);
  for (const code of ["revision_conflict", "sync_recovering", "sync_upgrade_required"]) {
    expect(syncMessage(code, "en")).toBeTruthy();
    expect(syncMessage(code, "ja")).toBeTruthy();
    expect(syncMessage(code, "en")).not.toBe(syncMessage(code, "ja"));
  }
});
