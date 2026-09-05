const ROUND_CONSTANTS = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

class IncrementalSha256 {
  private readonly state = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  private readonly block = new Uint8Array(64);
  private blockLength = 0;
  private byteLength = 0;

  update(bytes: Uint8Array): void {
    this.byteLength += bytes.byteLength;
    let offset = 0;
    while (offset < bytes.byteLength) {
      const length = Math.min(64 - this.blockLength, bytes.byteLength - offset);
      this.block.set(bytes.subarray(offset, offset + length), this.blockLength);
      this.blockLength += length;
      offset += length;
      if (this.blockLength === 64) {
        this.compress(this.block);
        this.blockLength = 0;
      }
    }
  }

  digestHex(): string {
    const tail = new Uint8Array(this.blockLength < 56 ? 64 : 128);
    tail.set(this.block.subarray(0, this.blockLength));
    tail[this.blockLength] = 0x80;
    const view = new DataView(tail.buffer);
    view.setUint32(tail.byteLength - 8, Math.floor(this.byteLength / 0x20000000));
    view.setUint32(tail.byteLength - 4, (this.byteLength << 3) >>> 0);
    for (let offset = 0; offset < tail.byteLength; offset += 64) this.compress(tail.subarray(offset, offset + 64));
    return [...this.state].map((word) => word.toString(16).padStart(8, "0")).join("");
  }

  private compress(block: Uint8Array): void {
    const words = new Uint32Array(64);
    const view = new DataView(block.buffer, block.byteOffset, block.byteLength);
    for (let index = 0; index < 16; index += 1) words[index] = view.getUint32(index * 4);
    for (let index = 16; index < 64; index += 1) {
      const a = words[index - 15]!;
      const b = words[index - 2]!;
      const s0 = rightRotate(a, 7) ^ rightRotate(a, 18) ^ (a >>> 3);
      const s1 = rightRotate(b, 17) ^ rightRotate(b, 19) ^ (b >>> 10);
      words[index] = (words[index - 16]! + s0 + words[index - 7]! + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = this.state;
    for (let index = 0; index < 64; index += 1) {
      const s1 = rightRotate(e!, 6) ^ rightRotate(e!, 11) ^ rightRotate(e!, 25);
      const choice = (e! & f!) ^ (~e! & g!);
      const first = (h! + s1 + choice + ROUND_CONSTANTS[index]! + words[index]!) >>> 0;
      const s0 = rightRotate(a!, 2) ^ rightRotate(a!, 13) ^ rightRotate(a!, 22);
      const majority = (a! & b!) ^ (a! & c!) ^ (b! & c!);
      const second = (s0 + majority) >>> 0;
      [a, b, c, d, e, f, g, h] = [(first + second) >>> 0, a, b, c, (d! + first) >>> 0, e, f, g];
    }
    for (const [index, value] of [a, b, c, d, e, f, g, h].entries()) {
      this.state[index] = (this.state[index]! + value!) >>> 0;
    }
  }
}

function rightRotate(value: number, amount: number): number {
  return (value >>> amount) | (value << (32 - amount));
}

export async function sha256Stream(
  value: ReadableStream<Uint8Array> | Uint8Array | null,
): Promise<string> {
  const hash = new IncrementalSha256();
  if (value instanceof Uint8Array) {
    hash.update(value);
  } else if (value) {
    const reader = value.getReader();
    while (true) {
      const { done, value: chunk } = await reader.read();
      if (done) break;
      hash.update(chunk);
    }
  }
  return hash.digestHex();
}

export function sha256Passthrough(value: ReadableStream<Uint8Array> | null): {
  body: ReadableStream<Uint8Array>;
  digest: Promise<string>;
} {
  const input = value ?? new ReadableStream<Uint8Array>({ start: (controller) => controller.close() });
  const reader = input.getReader();
  const hash = new IncrementalSha256();
  let resolveDigest!: (digest: string) => void;
  let rejectDigest!: (error: unknown) => void;
  const digest = new Promise<string>((resolve, reject) => {
    resolveDigest = resolve;
    rejectDigest = reject;
  });
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      try {
        const result = await reader.read();
        if (result.done) {
          resolveDigest(hash.digestHex());
          controller.close();
        } else {
          hash.update(result.value);
          controller.enqueue(result.value);
        }
      } catch (error) {
        rejectDigest(error);
        controller.error(error);
      }
    },
    async cancel(reason) {
      rejectDigest(reason);
      await reader.cancel(reason);
    },
  });
  return { body, digest };
}
