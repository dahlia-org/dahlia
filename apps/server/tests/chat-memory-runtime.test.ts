import { afterEach, describe, expect, it, vi } from "vitest";
import { Memory } from "@mastra/memory";
import { InMemoryStore } from "@mastra/core/storage";
import { mastraModel, requestMemoryModel } from "../src/agent/service";
import type { AppConfig } from "../src/config";
const secret = "PRIVATE_CHAT_ERROR_CONTENT";
const providerError = () => Object.assign(new Error(secret), { requestBodyValues: { input: secret }, responseBody: secret });
const config = { provider: { backend: "openai", baseUrl: "https://provider.example/v1", apiKey: "test" } } as AppConfig;
afterEach(() => vi.restoreAllMocks());
async function fixture(signal: AbortSignal) {
  const model = await mastraModel(config, "test", new Headers(), { userId: "user", source: "header" }, signal);
  const memory = new Memory({ storage: new InMemoryStore(), vector: false, options: { semanticRecall: false,
    observationalMemory: { scope: "thread", model: requestMemoryModel(model, signal),
      observation: { messageTokens: 1, bufferTokens: false }, reflection: { observationTokens: 1 } } } });
  await memory.createThread({ threadId: "thread", resourceId: "user" });
  await memory.saveMessages({ messages: [{ id: "message", threadId: "thread", resourceId: "user", role: "user",
    createdAt: new Date(), content: { format: 2, parts: [{ type: "text", text: secret.repeat(50) }] } }] });
  const engine = (await memory.omEngine)!;
  const store = (await memory.storage.getStore("memory"))!;
  const record = await store.initializeObservationalMemory({ threadId: "thread", resourceId: "user", scope: "thread", config: {} });
  await store.updateActiveObservations({ id: record.id, observations: secret.repeat(50), tokenCount: 100, lastObservedAt: new Date(0) });
  return { model, memory, run: (operation: "observe" | "reflect") => operation === "observe"
    ? engine.observe({ threadId: "thread", resourceId: "user" }) : engine.reflect("thread", "user") };
}
describe("OM inference boundaries", () => {
  for (const operation of ["observe", "reflect"] as const) {
    it(`keeps ${operation} provider failures out of content-bearing logs`, async () => {
      const logged = vi.spyOn(console, "error").mockImplementation(() => {});
      const { model, memory, run } = await fixture(new AbortController().signal);
      const stream = vi.spyOn(model, "doStream").mockRejectedValue(providerError());
      vi.spyOn(model, "doGenerate").mockRejectedValue(providerError());
      if (operation === "observe") await expect(run(operation)).rejects.toThrow();
      else expect((await run(operation)).reflected).toBe(false);
      await memory.settled();
      expect(stream).toHaveBeenCalled();
      expect(JSON.stringify(logged.mock.calls)).not.toContain(secret);
    });
    it(`aborts ${operation} inference and settles its memory work`, async () => {
      vi.spyOn(console, "error").mockImplementation(() => {});
      const controller = new AbortController();
      const { model, memory, run } = await fixture(controller.signal);
      let markStarted!: (signal: AbortSignal) => void;
      const started = new Promise<AbortSignal>((resolve) => { markStarted = resolve; });
      const invoke: typeof model.doStream = async (options) => {
        const signal = options.abortSignal!;
        markStarted(signal);
        return new Promise((_, reject) => {
          const abort = () => reject(providerError());
          if (signal.aborted) abort(); else signal.addEventListener("abort", abort, { once: true });
        });
      };
      vi.spyOn(model, "doStream").mockImplementation(invoke);
      vi.spyOn(model, "doGenerate").mockImplementation(invoke);
      const pending = run(operation);
      const rejected = operation === "observe" ? expect(pending).rejects.toThrow() : expect(pending).resolves.toMatchObject({ reflected: false });
      const signal = await started;
      controller.abort();
      expect(signal.aborted).toBe(true);
      await rejected;
      await memory.settled();
    });
  }
  it("redacts error chunks and rejected stream reads in both model entrypoints", async () => {
    const signal = new AbortController().signal;
    const model = await mastraModel(config, "test", new Headers(), { userId: "user", source: "header" }, signal);
    for (const method of ["doStream", "doGenerate"] as const) {
      for (const rejectedRead of [false, true]) {
        vi.spyOn(model, method).mockResolvedValue({ stream: new ReadableStream({ start(controller) {
          if (rejectedRead) controller.error(providerError());
          else { controller.enqueue({ type: "error", error: providerError() }); controller.close(); }
        } }) });
        const result = await requestMemoryModel(model, signal)[method]({ prompt: [] });
        const read = result.stream.getReader().read();
        if (rejectedRead) await expect(read).rejects.toThrow("memory_inference_failed");
        else expect((await read).value).toMatchObject({ type: "error", error: new Error("memory_inference_failed") });
      }
    }
  });
});
