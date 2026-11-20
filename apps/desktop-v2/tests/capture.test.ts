import { readFileSync } from "node:fs";
import vm from "node:vm";
import { createElement } from "react";
import { renderToString } from "react-dom/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DahliaAPI } from "../src/shared/types.js";

class Track extends EventTarget {
  readyState = "live";
  stop = vi.fn(() => { this.readyState = "ended"; });
  end() { this.readyState = "ended"; this.dispatchEvent(new Event("ended")); }
}
const stream = (track: Track) => ({ getTracks: () => [track], getAudioTracks: () => [track], getVideoTracks: () => [] }) as unknown as MediaStream;
let mic: Track;
let system: Track;
let events: string[];
let acknowledge: boolean;
let dahlia: DahliaAPI;
let append: ReturnType<typeof vi.fn>;
let stopped: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  events = [];
  acknowledge = true;
  mic = new Track();
  system = new Track();
  append = vi.fn(() => { events.push("append"); });
  stopped = vi.fn(async () => { events.push("main:stop"); });
  dahlia = {
    recording: {
      state: vi.fn(async () => ({ active: { meetingId: "m", recordingId: "r", startedAt: Date.now() } })),
      start: vi.fn(async () => ({ meetingId: "m", recordingId: "r", startedAt: Date.now() })),
      stop: stopped,
      append,
    },
  } as unknown as DahliaAPI;
  vi.stubGlobal("window", { dahlia });
  vi.stubGlobal("navigator", { mediaDevices: {
    getUserMedia: vi.fn(async () => stream(mic)),
    getDisplayMedia: vi.fn(async () => stream(system)),
  } });
  vi.stubGlobal("AudioContext", class {
    audioWorklet = { addModule: vi.fn(async () => {}) };
    destination = {};
    createGain() { return { gain: { value: 1 }, connect: vi.fn() }; }
    createMediaStreamSource() { return { connect: vi.fn() }; }
    close = vi.fn(async () => { events.push("context:close"); });
  });
  vi.stubGlobal("AudioWorkletNode", class {
    port = {
      onmessage: undefined as ((event: { data: { pcm?: ArrayBuffer; flushed?: boolean } }) => void) | undefined,
      postMessage: () => {
        events.push("flush");
        queueMicrotask(() => {
          this.port.onmessage?.({ data: { pcm: new ArrayBuffer(2) } });
          if (acknowledge) this.port.onmessage?.({ data: { flushed: true } });
        });
      },
    };
    connect = vi.fn();
  });
});
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

describe("capture stop", () => {
  it("flushes both sources before closing tracks and notifies on track loss", async () => {
    const { startCapture } = await import("../src/renderer/capture.js");
    const ended = vi.fn();
    const capture = await startCapture("r", stream(system), () => {}, ended);
    mic.end();
    expect(ended).toHaveBeenCalledOnce();
    await capture.stop();
    expect(append).toHaveBeenCalledTimes(2);
    expect(events.at(-1)).toBe("context:close");
    expect(mic.stop).toHaveBeenCalledOnce();
    expect(system.stop).toHaveBeenCalledOnce();
  });

  it("reports flush timeouts after releasing tracks", async () => {
    vi.useFakeTimers();
    acknowledge = false;
    const { startCapture } = await import("../src/renderer/capture.js");
    const capture = await startCapture("r", undefined, () => {}, () => {});
    const failed = expect(capture.stop()).rejects.toThrow("Capture flush failed");
    await vi.advanceTimersByTimeAsync(1000);
    await failed;
    expect(mic.stop).toHaveBeenCalledOnce();
    expect(events.at(-1)).toBe("context:close");
  });

  it("serializes a stop requested during startup and forwards a track failure", async () => {
    const { useRecorder } = await import("../src/renderer/capture.js");
    let recorder!: ReturnType<typeof useRecorder>;
    function Harness() { recorder = useRecorder(); return null; }
    renderToString(createElement(Harness));
    const starting = recorder.start("m");
    const stopping = recorder.stop("captureEnded");
    expect(recorder.stop()).toBe(stopping);
    await starting;
    await stopping;
    expect(stopped).toHaveBeenCalledWith("r", "captureEnded");
    expect(events.at(-1)).toBe("main:stop");
    expect(events.indexOf("append")).toBeLessThan(events.indexOf("main:stop"));
  });
});

it("worklet stops accepting input once it acknowledges the final partial chunk", () => {
  let Processor!: new () => { process(input: Float32Array[][]): boolean; port: { onmessage: (event: { data: string }) => void; postMessage: ReturnType<typeof vi.fn> } };
  class Base { port = { onmessage: undefined, postMessage: vi.fn() }; }
  vm.runInNewContext(readFileSync(new URL("../src/renderer/public/pcm-worklet.js", import.meta.url), "utf8"), {
    AudioWorkletProcessor: Base, sampleRate: 16_000,
    registerProcessor: (_: string, implementation: typeof Processor) => { Processor = implementation; },
  });
  const processor = new Processor();
  processor.process([[new Float32Array(128)]]);
  processor.port.onmessage({ data: "flush" });
  expect(processor.port.postMessage).toHaveBeenCalledTimes(2);
  expect(processor.port.postMessage.mock.calls[0]?.[0]).toHaveProperty("pcm");
  expect(processor.port.postMessage.mock.calls[1]?.[0]).toEqual({ flushed: true });
  expect(processor.process([[new Float32Array(128)]])).toBe(false);
});
