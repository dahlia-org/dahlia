import { describe, expect, it, vi } from "vitest";
import { createQueueJobs, jobMessageSchema, type WorkerJobStores } from "../src/jobs/queues";
import { closeAfterResponse, createWorkerHandler, type WorkerApp } from "../src/worker";

function setup() {
  const send = vi.fn().mockResolvedValue(undefined);
  const queue = { claim: vi.fn().mockResolvedValue(null), nextDelay: vi.fn().mockResolvedValue(undefined),
    scheduleMaintenance: vi.fn().mockResolvedValue(undefined), complete: vi.fn().mockResolvedValue(undefined) };
  const sync = { drainStorageDeletes: vi.fn().mockResolvedValue(undefined) };
  const jobs = createQueueJobs({ DAHLIA_JOB_QUEUE: { send, sendBatch: vi.fn() } }, { queue } as unknown as WorkerJobStores,
    {} as never, sync as never, []);
  return { jobs, queue, send, sync };
}
describe("shared Worker job delivery", () => {
  it("recovers failed post-commit hints from cron without putting content in messages", async () => {
    const { jobs, queue, send } = setup();
    send.mockRejectedValueOnce(new Error("unavailable"));
    await jobs.notify();
    await jobs.schedule();
    expect(queue.scheduleMaintenance).toHaveBeenCalledOnce();
    expect(send).toHaveBeenLastCalledWith({ action: "wake" });
    await jobs.consume({ action: "wake" }, new AbortController().signal);
    expect(queue.claim).toHaveBeenCalledTimes(8);
    expect(jobMessageSchema.safeParse({ action: "wake", text: "private" }).success).toBe(false);
    expect(jobMessageSchema.safeParse({ action: "run", reference: "private" }).success).toBe(false);
  });
  it("drains durable storage work from cron even while every producer hint fails", async () => {
    const { jobs, queue, send, sync } = setup();
    send.mockRejectedValue(new Error("producer unavailable"));
    queue.claim.mockResolvedValueOnce({ id: "storage-delete:key", kind: "storage-delete", payload: { storageKey: "key" },
      batch: [{}], createdAt: new Date() });
    await jobs.schedule();
    expect(sync.drainStorageDeletes).toHaveBeenCalledWith("key", expect.objectContaining({ id: "storage-delete:key" }));
    expect(queue.complete).toHaveBeenCalledOnce();
    expect(queue.claim).toHaveBeenCalledTimes(4);
    expect(send).toHaveBeenCalledOnce();
  });
  it("reschedules according to durable availability and exposes DB failures for queue retry", async () => {
    const { jobs, queue, send } = setup();
    queue.nextDelay.mockResolvedValue(30);
    await jobs.consume({ action: "wake" }, new AbortController().signal);
    expect(send).toHaveBeenLastCalledWith({ action: "wake" }, { delaySeconds: 30 });
    queue.nextDelay.mockResolvedValue(60);
    send.mockClear();
    await jobs.consume({ action: "wake" }, new AbortController().signal);
    expect(send).not.toHaveBeenCalled();
    queue.claim.mockRejectedValue(new Error("database unavailable"));
    await expect(jobs.consume({ action: "wake" }, new AbortController().signal)).rejects.toThrow("database unavailable");
  });
  it("waits for every admitted claim before propagating an event failure", async () => {
    const { jobs, queue } = setup();
    let release!: () => void;
    const blocked = new Promise<null>((resolve) => { release = () => resolve(null); });
    queue.claim.mockRejectedValueOnce(new Error("database unavailable")).mockReturnValueOnce(blocked);
    let settled = false;
    const consumed = jobs.consume({ action: "wake" }, new AbortController().signal).catch(() => { settled = true; });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(settled).toBe(false);
    release();
    await consumed;
    expect(settled).toBe(true);
  });
  it("closes the cron connection after failed registration, with no independent maintenance execution", async () => {
    const close = vi.fn(), runStorageMaintenance = vi.fn();
    const handler = createWorkerHandler(async () => ({ jobs: { schedule: async () => { throw new Error("database unavailable"); } },
      close, runStorageMaintenance }) as unknown as WorkerApp);
    await expect(handler.scheduled!({} as never, {}, {} as never)).rejects.toThrow("database unavailable");
    expect(close).toHaveBeenCalledOnce();
    expect(runStorageMaintenance).not.toHaveBeenCalled();
  });
  it("acks completed work, retries failure and closes the event connection", async () => {
    const consume = vi.fn().mockResolvedValueOnce(undefined).mockRejectedValueOnce(new Error("db"));
    const close = vi.fn();
    const handler = createWorkerHandler(async () => ({ jobs: { consume }, close }) as unknown as WorkerApp);
    const messages = [0, 1].map((body) => ({ body, ack: vi.fn(), retry: vi.fn() }));
    await handler.queue!({ messages } as never, {}, {} as never);
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
