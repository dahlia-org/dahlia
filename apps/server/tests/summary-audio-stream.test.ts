import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { audioBase64 } from "../src/summary/audio";

const checksum = (bytes: Uint8Array) => `SHA-256:${createHash("sha256").update(bytes).digest("hex")}`;
async function read(response: Response, bytes: Uint8Array, signal = new AbortController().signal) {
  let text = "";
  for await (const part of audioBase64(response, bytes.length, checksum(bytes), signal)) text += part;
  return text;
}

describe("audio base64 streaming", () => {
  it.each([1, 2, 3, 4, 5, 64, 65536])("preserves bytes across %i-byte storage chunks", async (size) => {
    const bytes = Uint8Array.from({ length: 65539 }, (_, index) => index % 256);
    let offset = 0;
    const body = new ReadableStream<Uint8Array>({ pull(controller) {
      if (offset === bytes.length) { controller.close(); return; }
      controller.enqueue(bytes.slice(offset, offset + size)); offset = Math.min(bytes.length, offset + size);
    } });
    expect(await read(new Response(body), bytes)).toBe(Buffer.from(bytes).toString("base64"));
  });
  it("rejects truncation, extra bytes, and checksum changes", async () => {
    const bytes = new Uint8Array([1, 2, 3]);
    for (const actual of [bytes.slice(1), new Uint8Array([1, 2, 3, 4]), new Uint8Array([1, 2, 4])]) {
      await expect(read(new Response(actual), bytes)).rejects.toThrow("summary_audio_changed");
    }
  });
  it("cancels an in-flight storage read on abort", async () => {
    const abort = new AbortController(); const cancel = vi.fn();
    const body = new ReadableStream<Uint8Array>({ cancel });
    const result = read(new Response(body), new Uint8Array([1]), abort.signal);
    abort.abort();
    await expect(result).rejects.toThrow();
    expect(cancel).toHaveBeenCalledOnce();
  });
});
