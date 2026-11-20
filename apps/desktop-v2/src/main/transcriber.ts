// Runs the bundled dahlia-transcribe helper, one process per source file, and reads its JSON Lines output. A separate
// process keeps a crash or a stall in Apple Speech away from the main process, which owns the recording.
import { spawn } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { createInterface } from "node:readline";
import { audioSources, type AudioSource } from "../shared/types.js";
import { audioFile, sampleRate } from "./recorder.js";

/** No output for this long means the helper is stuck; Dahlia for macOS stops a stalled analysis the same way. */
export const stallTimeoutMs = 5 * 60_000;

export type HelperSegment = { startMs: number; endMs: number; text: string };
export type TranscribedSegment = HelperSegment & { source: AudioSource };
export type HelperProgress = { type: "asset"; fraction: number } | { type: "progress"; processedMs: number };

/** Why a transcription failed; the codes are the helper's, plus the ones this side detects. */
export class TranscriptionError extends Error {
  constructor(readonly code: "unsupported_locale" | "assets_unavailable" | "invalid_audio" | "failed" | "stalled" | "missing_helper" | "cancelled") {
    super(code);
  }
}

const helperCodes = new Set(["unsupported_locale", "assets_unavailable", "invalid_audio", "failed"]);

/** Runs the helper with `args` and resolves with its parsed lines once it prints `done` and exits 0. */
export function runHelper(
  executable: string,
  args: string[],
  onLine: (line: Record<string, unknown>) => void,
  signal: AbortSignal,
  stallMs = stallTimeoutMs,
): Promise<void> {
  if (!existsSync(executable)) return Promise.reject(new TranscriptionError("missing_helper"));
  return new Promise((resolve, reject) => {
    // Arguments go straight to the process; there is no shell.
    const child = spawn(executable, args, { stdio: ["ignore", "pipe", "ignore"] });
    let done = false;
    let failure: TranscriptionError | undefined;
    let timer: NodeJS.Timeout | undefined;
    const fail = (error: TranscriptionError) => {
      failure ??= error;
      child.kill("SIGKILL");
    };
    const arm = () => {
      clearTimeout(timer);
      timer = setTimeout(() => fail(new TranscriptionError("stalled")), stallMs);
    };
    const abort = () => fail(new TranscriptionError("cancelled"));
    if (signal.aborted) abort();
    signal.addEventListener("abort", abort, { once: true });
    arm();
    createInterface({ input: child.stdout }).on("line", (raw) => {
      arm();
      let line: Record<string, unknown>;
      try {
        line = JSON.parse(raw) as Record<string, unknown>;
      } catch {
        return fail(new TranscriptionError("failed"));
      }
      if (line.type === "done") done = true;
      else if (line.type === "error") failure ??= new TranscriptionError(helperCodes.has(line.code as string) ? (line.code as "failed") : "failed");
      else onLine(line);
    });
    child.on("error", () => fail(new TranscriptionError("missing_helper")));
    child.on("close", (code) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      if (!failure && done && code === 0) resolve();
      else reject(failure ?? new TranscriptionError("failed"));
    });
  });
}

export async function transcribeFile(
  executable: string,
  file: string,
  locale: string,
  onProgress: (progress: HelperProgress) => void,
  signal: AbortSignal,
): Promise<HelperSegment[]> {
  const segments: HelperSegment[] = [];
  await runHelper(executable, ["transcribe", "--locale", locale, "--sample-rate", String(sampleRate), file], (line) => {
    if (line.type === "segment" && typeof line.text === "string" && typeof line.start_ms === "number" && typeof line.end_ms === "number") {
      segments.push({ startMs: line.start_ms, endMs: line.end_ms, text: line.text });
    } else if (line.type === "asset" && typeof line.fraction === "number") {
      onProgress({ type: "asset", fraction: line.fraction });
    } else if (line.type === "progress" && typeof line.processed_ms === "number") {
      onProgress({ type: "progress", processedMs: line.processed_ms });
    }
  }, signal);
  return segments;
}

/** Transcribes each source of a recording in turn (the system limits simultaneous analyses) and merges them in time order. */
export async function transcribeRecording(
  executable: string,
  directory: string,
  locale: string,
  onProgress: (progress: HelperProgress & { source: AudioSource }) => void,
  signal: AbortSignal,
): Promise<TranscribedSegment[]> {
  const merged: TranscribedSegment[] = [];
  for (const source of audioSources) {
    const file = audioFile(directory, source);
    if (!existsSync(file) || statSync(file).size < 2) continue;
    const segments = await transcribeFile(executable, file, locale, (progress) => onProgress({ ...progress, source }), signal);
    merged.push(...segments.map((segment) => ({ ...segment, source })));
  }
  return sortSegments(merged);
}

/** Time order; at the same moment the microphone comes first, as in Dahlia for macOS. */
export function sortSegments<T extends { startMs: number; source: AudioSource }>(segments: T[]): T[] {
  return [...segments].sort((a, b) => a.startMs - b.startMs || audioSources.indexOf(a.source) - audioSources.indexOf(b.source));
}

export async function listLocales(executable: string, signal: AbortSignal): Promise<string[]> {
  let locales: string[] = [];
  await runHelper(executable, ["locales"], (line) => {
    if (line.type === "locales" && Array.isArray(line.locales)) locales = line.locales.filter((item): item is string => typeof item === "string");
  }, signal, 60_000);
  return locales;
}
