import { describe, expect, it } from "vitest";

import { sha256Passthrough, sha256Stream } from "../src/artifacts/sha256";

describe("streaming SHA-256", () => {
  it("hashes incrementally without combining the input chunks", async () => {
    const encoder = new TextEncoder();
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        for (const part of ["a", "bc", "defghijklmnopqrstuvwxyz"]) controller.enqueue(encoder.encode(part));
        controller.close();
      },
    });

    expect(await sha256Stream(stream)).toBe("71c480df93d6ae2f1efad1447c66c9525e316218cf51fc8d9ed832f2daf18b73");
    expect(await sha256Stream(new Uint8Array())).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  });

  it("hashes the same chunks that the storage consumer drains", async () => {
    const bytes = Uint8Array.from({ length: 1_000 }, (_, index) => index % 251);
    const expected = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
      .map((byte) => byte.toString(16).padStart(2, "0")).join("");
    const upload = sha256Passthrough(new Blob([
      bytes.subarray(0, 13),
      bytes.subarray(13, 259),
      bytes.subarray(259),
    ]).stream());

    expect(new Uint8Array(await new Response(upload.body).arrayBuffer())).toEqual(bytes);
    expect(await upload.digest).toBe(expected);
  });
});
