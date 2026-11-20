import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { audioFile } from "../src/main/recorder.js";
import { listLocales, runHelper, sortSegments, transcribeRecording } from "../src/main/transcriber.js";

/** A stand-in for dahlia-transcribe: a Node script that prints `lines` (per file name in its last argument) and exits. */
function fakeHelper(script: string) {
  const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-helper-"));
  const file = join(directory, "helper");
  writeFileSync(file, `#!/usr/bin/env node\nconst args = process.argv.slice(2);\nconst out = (o) => process.stdout.write(JSON.stringify(o) + "\\n");\n${script}\n`);
  chmodSync(file, 0o755);
  return file;
}

const never = new AbortController().signal;

describe("runHelper", () => {
  it("resolves only after done and a zero exit", async () => {
    const lines: unknown[] = [];
    await runHelper(fakeHelper(`out({ type: "segment", text: "a", start_ms: 0, end_ms: 1 }); out({ type: "done" });`), [], (line) => lines.push(line), never);
    expect(lines).toEqual([{ type: "segment", text: "a", start_ms: 0, end_ms: 1 }]);
  });

  it("rejects with the helper's error code", async () => {
    await expect(runHelper(fakeHelper(`out({ type: "error", code: "unsupported_locale" }); process.exit(1);`), [], () => {}, never))
      .rejects.toMatchObject({ code: "unsupported_locale" });
  });

  it("does not accept a result without done, even with exit 0", async () => {
    await expect(runHelper(fakeHelper(`out({ type: "segment", text: "partial", start_ms: 0, end_ms: 1 });`), [], () => {}, never))
      .rejects.toMatchObject({ code: "failed" });
  });

  it("stops a helper that goes quiet", async () => {
    await expect(runHelper(fakeHelper(`setTimeout(() => {}, 60000);`), [], () => {}, never, 200)).rejects.toMatchObject({ code: "stalled" });
  });

  it("stops when cancelled and reports a missing helper", async () => {
    const controller = new AbortController();
    const pending = runHelper(fakeHelper(`setTimeout(() => {}, 60000);`), [], () => {}, controller.signal);
    controller.abort();
    await expect(pending).rejects.toMatchObject({ code: "cancelled" });
    await expect(runHelper("/nonexistent/helper", [], () => {}, never)).rejects.toMatchObject({ code: "missing_helper" });
  });
});

describe("transcribeRecording", () => {
  it("transcribes each source that has audio, passing the locale, and merges in time order", async () => {
    const helper = fakeHelper(`
      const file = args.at(-1);
      if (args[2] !== "ja-JP" || args[4] !== "16000") { out({ type: "error", code: "failed" }); process.exit(1); }
      if (file.endsWith("mic.pcm")) { out({ type: "segment", text: "mic 2s", start_ms: 2000, end_ms: 3000 }); out({ type: "segment", text: "mic 5s", start_ms: 5000, end_ms: 6000 }); }
      else out({ type: "segment", text: "system 2s", start_ms: 2000, end_ms: 2500 });
      out({ type: "progress", processed_ms: 1000 });
      out({ type: "done" });`);
    const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-rec-"));
    writeFileSync(audioFile(directory, "mic"), new Uint8Array(64));
    writeFileSync(audioFile(directory, "system"), new Uint8Array(64));
    const progress: unknown[] = [];
    const segments = await transcribeRecording(helper, directory, "ja-JP", (item) => progress.push(item), never);
    expect(segments.map((segment) => `${segment.source}:${segment.text}`)).toEqual(["mic:mic 2s", "system:system 2s", "mic:mic 5s"]);
    expect(progress).toEqual([{ type: "progress", processedMs: 1000, source: "mic" }, { type: "progress", processedMs: 1000, source: "system" }]);
  });

  it("skips a source with no audio", async () => {
    const helper = fakeHelper(`out({ type: "segment", text: args.at(-1).endsWith("mic.pcm") ? "mic" : "system", start_ms: 0, end_ms: 1 }); out({ type: "done" });`);
    const directory = mkdtempSync(join(tmpdir(), "dahlia-v2-rec-"));
    writeFileSync(audioFile(directory, "mic"), new Uint8Array(64));
    writeFileSync(audioFile(directory, "system"), new Uint8Array(0));
    expect((await transcribeRecording(helper, directory, "ja-JP", () => {}, never)).map((segment) => segment.text)).toEqual(["mic"]);
  });
});

describe("listLocales", () => {
  it("returns the helper's locales", async () => {
    expect(await listLocales(fakeHelper(`out({ type: "locales", locales: ["en-US", "ja-JP", 3] }); out({ type: "done" });`), never)).toEqual(["en-US", "ja-JP"]);
  });
});

describe("sortSegments", () => {
  it("orders by time, microphone first at the same moment", () => {
    expect(sortSegments([{ startMs: 5, source: "system" as const }, { startMs: 5, source: "mic" as const }, { startMs: 1, source: "system" as const }]))
      .toEqual([{ startMs: 1, source: "system" }, { startMs: 5, source: "mic" }, { startMs: 5, source: "system" }]);
  });
});
