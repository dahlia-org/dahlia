// Recording files: one headerless 16 kHz mono 16-bit PCM file per source, appended and never rewritten. Without a header
// a crash leaves a readable file up to the last successful flush. Capture and IPC buffers are not crash-durable.
import { closeSync, fstatSync, fsyncSync, mkdirSync, openSync, rmSync, statSync, writeSync } from "node:fs";
import { join } from "node:path";
import { audioSources, type AudioSource } from "../shared/types.js";

export const sampleRate = 16_000;
export const flushIntervalMs = 5_000;
/** A chunk is about a second of audio; anything far larger is not from the recorder. */
export const maxChunkBytes = sampleRate * 2 * 10;

export const recordingDirectory = (root: string, meetingId: string, recordingId: string) => join(root, meetingId, recordingId);
export const audioFile = (directory: string, source: AudioSource) => join(directory, `${source}.pcm`);
export const durationFromBytes = (bytes: number) => Math.round(Math.floor(bytes / 2) / (sampleRate / 1000));

export class RecordingWriter {
  private readonly files = new Map<AudioSource, { fd: number; bytes: number }>();
  private readonly timer: NodeJS.Timeout;

  constructor(readonly recordingId: string, readonly directory: string, onError: () => void) {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    try {
      for (const source of audioSources) {
        // Append mode: an existing file (a resumed id) is extended, never truncated.
        const fd = openSync(audioFile(directory, source), "a", 0o600);
        this.files.set(source, { fd, bytes: 0 });
        this.files.get(source)!.bytes = fstatSync(fd).size;
      }
    } catch (error) {
      for (const { fd } of this.files.values()) {
        try { closeSync(fd); } catch { /* Keep closing the other source. */ }
      }
      throw error;
    }
    this.timer = setInterval(() => {
      try {
        this.flush();
      } catch {
        clearInterval(this.timer);
        onError();
      }
    }, flushIntervalMs);
  }

  /** Appends one chunk. Throws on a write failure, which must stop the recording visibly. */
  append(source: AudioSource, chunk: Uint8Array) {
    const file = this.files.get(source);
    if (!file) throw new Error("Unknown audio source");
    if (chunk.byteLength === 0 || chunk.byteLength % 2 !== 0 || chunk.byteLength > maxChunkBytes) throw new Error("Invalid audio chunk");
    let written = 0;
    while (written < chunk.byteLength) {
      const count = writeSync(file.fd, chunk, written, chunk.byteLength - written);
      if (count === 0) throw new Error("Audio write made no progress");
      written += count;
      file.bytes += count;
    }
  }

  flush() {
    for (const { fd } of this.files.values()) fsyncSync(fd);
  }

  /** Flushes, closes and returns the length of the longer source. */
  close(): number {
    clearInterval(this.timer);
    let bytes = 0;
    let failure: unknown;
    for (const { fd, bytes: size } of this.files.values()) {
      bytes = Math.max(bytes, size);
      try {
        fsyncSync(fd);
      } catch (error) { failure ??= error; }
      try { closeSync(fd); } catch (error) { failure ??= error; }
    }
    this.files.clear();
    if (failure) throw failure instanceof Error ? failure : new Error("Audio close failed");
    return durationFromBytes(bytes);
  }
}

/** The length a recording reached before the app stopped, from its files. */
export function recoveredDurationMs(directory: string): number {
  let bytes = 0;
  for (const source of audioSources) {
    try {
      bytes = Math.max(bytes, statSync(audioFile(directory, source)).size);
    } catch (error) {
      // Missing is empty; an unreadable file is not evidence that its audio can be deleted.
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  return durationFromBytes(bytes);
}

export function removeMeetingAudio(root: string, meetingId: string) {
  rmSync(join(root, meetingId), { recursive: true, force: true });
}
