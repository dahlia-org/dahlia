import { afterEach, describe, expect, it, vi } from "vitest";
import { generateMemoryDraft } from "../src/client/memory-draft";
const input = { question: "What did we decide?", answer: "A proposal, not yet agreed.", draft: "Keep the qualification." };
const response = (text: string, status = "completed") => Response.json({ status, output: [
  { type: "reasoning", summary: [] }, { type: "message", content: [{ type: "output_text", text }] },
] });
afterEach(() => vi.unstubAllGlobals());
describe("memory draft via Responses", () => {
  it("sends the selected model and question/answer/edits without storing or saving", async () => {
    const transport = vi.fn<typeof fetch>(async () => response(JSON.stringify({ content: "A qualified note" })));
    vi.stubGlobal("fetch", transport);
    const signal = new AbortController().signal;
    expect(await generateMemoryDraft("selected-model", input, signal)).toBe("A qualified note");
    expect(transport).toHaveBeenCalledOnce();
    const [url, init] = transport.mock.calls[0]!;
    expect(url).toBe("/api/v1/responses");
    const body = JSON.parse(init!.body as string) as { model: string; input: string; store: boolean; stream: boolean };
    expect(body).toMatchObject({ model: "selected-model", store: false, stream: false });
    expect(JSON.parse(body.input)).toEqual(input);
    expect(init!.signal?.aborted).toBe(false);
  });
  it.each([['{"content":"partial"}', "incomplete"], ['{"content":""}', "completed"], ["not json", "completed"]])("rejects unusable draft output %s %s", async (text, status) => {
    vi.stubGlobal("fetch", vi.fn(async () => response(text, status)));
    await expect(generateMemoryDraft("model", input, new AbortController().signal)).rejects.toThrow();
  });
  it("does not publish a response after cancellation", async () => {
    const controller = new AbortController();
    vi.stubGlobal("fetch", vi.fn(async () => { controller.abort(); return response('{"content":"late"}'); }));
    await expect(generateMemoryDraft("model", input, controller.signal)).rejects.toThrow();
  });
});
