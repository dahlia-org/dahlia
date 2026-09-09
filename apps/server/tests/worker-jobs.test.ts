import { describe, expect, it, vi } from "vitest";
import { createQueueJobs, jobMessageSchema, type JobMessage, type JobQueue, type WorkerJobStores } from "../src/jobs/queues";
import { closeAfterResponse, createWorkerHandler, type WorkerApp } from "../src/worker";
import type { MeetingSyncStore } from "../src/sync/types";
import type { MeetingSyncService } from "../src/sync/service";
import type { AccountSettingsStore } from "../src/account-settings";
import { uuidV7 } from "../src/id";

function setup(imageQueue?: JobQueue) {
  const sent: JobMessage[] = [];
  const queue = { send: vi.fn((body: JobMessage) => { sent.push(body); return Promise.resolve(); }),
    sendBatch: vi.fn((messages: { body: JobMessage }[]) => { sent.push(...messages.map((entry) => entry.body)); return Promise.resolve(); }) };
  const stores = { listJobOwners: vi.fn(() => Promise.resolve(["owner"])),
    summaryJobs: { due: vi.fn(() => Promise.resolve([{ id: uuidV7(), ownerUserId: "owner" }])), claim: vi.fn(() => Promise.resolve(null)) },
  };
  const jobs = createQueueJobs({ DAHLIA_SUMMARY_QUEUE: queue, DAHLIA_IMAGE_QUEUE: imageQueue }, stores as unknown as WorkerJobStores,
    {} as MeetingSyncStore, {} as MeetingSyncService, {} as AccountSettingsStore, [{ id: "transcript" }] as never, imageQueue ? { model: "synthetic" } as never : undefined);
  return { queue, stores, jobs, sent };
}
const signal = () => new AbortController().signal;
describe("Worker job delivery", () => {
  it("settles all scheduled sends before surfacing a queue failure", async () => {
    let release!: () => void;
    const pending = new Promise<void>((resolve) => { release = resolve; });
    const imageQueue = { send: () => pending, sendBatch: () => pending };
    const { jobs, queue } = setup(imageQueue);
    queue.send.mockRejectedValueOnce(new Error("queue unavailable"));
    let settled = false;
    const scheduling = jobs.schedule().finally(() => { settled = true; });
    const rejection = expect(scheduling).rejects.toThrow("queue unavailable");
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(settled).toBe(false);
    release();
    await rejection;
  });
  it.each([false, true])("awaits maintenance after scheduling failure and closes on maintenance failure=%s", async (failMaintenance) => {
    let markStarted!: () => void, finish!: () => void, fail!: (error: Error) => void;
    const started = new Promise<void>((resolve) => { markStarted = resolve; });
    const maintenance = new Promise<void>((resolve, reject) => { finish = resolve; fail = reject; });
    const close = vi.fn(() => Promise.resolve());
    const schedule = vi.fn(() => Promise.reject(new Error("queue unavailable")));
    const runStorageMaintenance = vi.fn(() => { markStarted(); return maintenance; });
    const handler = createWorkerHandler(() => Promise.resolve({ jobs: { schedule }, runStorageMaintenance, close } as unknown as WorkerApp));
    const scheduled = handler.scheduled!({} as ScheduledController, {}, {} as ExecutionContext);
    const rejection = expect(scheduled).rejects.toThrow(failMaintenance ? "maintenance failed" : "queue unavailable");
    await started;
    expect(close).not.toHaveBeenCalled();
    if (failMaintenance) fail(new Error("maintenance failed"));
    else finish();
    await rejection;
    expect(runStorageMaintenance).toHaveBeenCalledOnce();
    expect(close).toHaveBeenCalledOnce();
  });

  it("recovers a failed post-commit notification by enumerating owners and dispatching canonical due references", async () => {
    const { jobs, queue, sent, stores } = setup();
    vi.spyOn(console, "warn").mockImplementation(() => {});
    queue.send.mockRejectedValueOnce(new Error("unavailable"));
    await jobs.notify("owner");
    await jobs.schedule();
    await jobs.consume(sent.shift(), signal());
    await jobs.consume(sent.shift(), signal());
    const run = sent.shift();
    expect(run).toMatchObject({ action: "run", kind: "summary", reference: { ownerUserId: "owner" } });
    await jobs.consume(run, signal());
    await jobs.consume(run, signal());
    expect(stores.summaryJobs.claim).toHaveBeenCalledTimes(2);
    expect(stores.summaryJobs.claim).toHaveBeenLastCalledWith((run as Extract<JobMessage, { action: "run"; kind: "summary" }>).reference);
    vi.restoreAllMocks();
  });
  it("rejects content-bearing, cross-kind and oversized messages", () => {
    const reference = { id: uuidV7(), ownerUserId: "owner" };
    expect(jobMessageSchema.safeParse({ action: "run", kind: "summary", reference, text: "private" }).success).toBe(false);
    expect(jobMessageSchema.safeParse({ action: "scan", kind: "summary", ownerUserId: "owner", phase: "dispatch", after: `${uuidV7()}/${uuidV7()}` }).success).toBe(false);
    expect(jobMessageSchema.safeParse({ action: "run", kind: "search", references: Array(17).fill({ vaultId: uuidV7(), documentId: uuidV7(), ownerUserId: "owner", generation: 1 }) }).success).toBe(false);
  });
  it("propagates database failure for native Queue retry", async () => {
    const { jobs, stores } = setup();
    stores.summaryJobs.claim.mockRejectedValueOnce(new Error("database unavailable"));
    await expect(jobs.consume({ action: "run", kind: "summary", reference: { id: uuidV7(), ownerUserId: "owner" } }, signal())).rejects.toThrow("database unavailable");
  });
  it("acks completed work, retries storage failure and closes the event connection", async () => {
    const consume = vi.fn().mockResolvedValueOnce(undefined).mockRejectedValueOnce(new Error("db"));
    const close = vi.fn(() => Promise.resolve());
    const handler = createWorkerHandler(() => Promise.resolve({ jobs: { consume }, close } as unknown as WorkerApp));
    const messages = [0, 1].map((body) => ({ body, ack: vi.fn(), retry: vi.fn() }));
    await handler.queue!({ messages } as never, {}, {} as ExecutionContext);
    expect(messages[0]!.ack).toHaveBeenCalledOnce();
    expect(messages[1]!.retry).toHaveBeenCalledOnce();
    expect(close).toHaveBeenCalledOnce();
  });
});

describe("event-scoped response connections", () => {
  it.each(["complete", "cancel", "error"])("keeps the connection until stream %s", async (mode) => {
    const close = vi.fn(() => Promise.resolve());
    let controller!: ReadableStreamDefaultController<Uint8Array>;
    const source = new ReadableStream<Uint8Array>({ start(value) { controller = value; } });
    const response = await closeAfterResponse(new Response(source), close);
    expect(close).not.toHaveBeenCalled();
    if (mode === "cancel") await response.body!.cancel();
    else if (mode === "error") { controller.error(new Error("read failed")); await expect(response.text()).rejects.toThrow("read failed"); }
    else { controller.enqueue(new TextEncoder().encode("ok")); controller.close(); expect(await response.text()).toBe("ok"); }
    expect(close).toHaveBeenCalledOnce();
  });
});
