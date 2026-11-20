import { closeSync, fsyncSync, mkdtempSync, readFileSync, statSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { audioFile, flushIntervalMs, recoveredDurationMs, RecordingWriter } from "../src/main/recorder.js";

vi.mock("node:fs", async (importOriginal) => {
  const fs = await importOriginal<typeof import("node:fs")>();
  return { ...fs, fsyncSync: vi.fn(fs.fsyncSync), closeSync: vi.fn(fs.closeSync), statSync: vi.fn(fs.statSync), writeSync: vi.fn(fs.writeSync) };
});
afterEach(() => { vi.clearAllMocks(); vi.useRealTimers(); });

const second = new Uint8Array(32_000);

describe("RecordingWriter", () => {
  it("appends each source to its own file and reports the longer one", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-rec-"));
    const writer = new RecordingWriter("r", directory, () => {});
    writer.append("mic", second);
    writer.append("mic", second);
    writer.append("system", second);
    expect(writer.close()).toBe(2000);
    expect(readFileSync(audioFile(directory, "mic")).byteLength).toBe(64_000);
    expect(readFileSync(audioFile(directory, "system")).byteLength).toBe(32_000);
  });

  it("extends an existing file instead of truncating it", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-rec-"));
    writeFileSync(audioFile(directory, "mic"), second);
    const writer = new RecordingWriter("r", directory, () => {});
    writer.append("mic", second);
    expect(writer.close()).toBe(2000);
  });

  it("rejects chunks that cannot be 16-bit audio", () => {
    const writer = new RecordingWriter("r", mkdtempSync(join(tmpdir(), "dahlia-v2-rec-")), () => {});
    expect(() => writer.append("mic", new Uint8Array(3))).toThrow();
    expect(() => writer.append("mic", new Uint8Array(0))).toThrow();
    expect(() => writer.append("mic", new Uint8Array(32_000 * 11))).toThrow();
    writer.close();
  });

  it("closes every source and keeps audio when fsync fails", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-rec-"));
    const writer = new RecordingWriter("r", directory, () => {});
    writer.append("mic", second);
    vi.mocked(fsyncSync).mockImplementationOnce(() => { throw new Error("EIO"); });
    expect(() => writer.close()).toThrow("EIO");
    expect(closeSync).toHaveBeenCalledTimes(2);
    expect(recoveredDurationMs(directory)).toBe(1000);
  });

  it("notifies the owner when a periodic flush fails", () => {
    vi.useFakeTimers();
    const onError = vi.fn();
    const writer = new RecordingWriter("r", mkdtempSync(join(tmpdir(), "dahlia-v2-rec-")), onError);
    writer.append("mic", second);
    vi.mocked(fsyncSync).mockImplementationOnce(() => { throw new Error("EIO"); });
    vi.advanceTimersByTime(flushIntervalMs * 2);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(writer.close()).toBe(1000);
  });

  it("accounts for bytes written before a partial-write failure", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-rec-"));
    const writer = new RecordingWriter("r", directory, () => {});
    const realWrite = (await vi.importActual<typeof import("node:fs")>("node:fs")).writeSync;
    vi.mocked(writeSync).mockImplementationOnce((fd) => realWrite(fd, second, 0, 16_000))
      .mockImplementationOnce(() => { throw new Error("ENOSPC"); });
    expect(() => writer.append("mic", second)).toThrow("ENOSPC");
    expect(writer.close()).toBe(500);
    expect(recoveredDurationMs(directory)).toBe(500);
  });

  it("does not classify unreadable audio as empty during recovery", () => {
    vi.mocked(statSync).mockImplementationOnce(() => { throw Object.assign(new Error("EIO"), { code: "EIO" }); });
    expect(() => recoveredDurationMs("/unreadable")).toThrow("EIO");
  });

  it("recovers a recording's length from its files, ignoring a half sample", () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-rec-"));
    writeFileSync(audioFile(directory, "system"), new Uint8Array(48_001));
    expect(recoveredDurationMs(directory)).toBe(1500);
    expect(recoveredDurationMs(join(directory, "missing"))).toBe(0);
  });
});
