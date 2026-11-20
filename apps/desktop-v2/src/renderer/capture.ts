// Audio capture in the renderer: the microphone and the Mac's audio output, each as 16 kHz mono 16-bit PCM chunks.
import { useCallback, useEffect, useRef, useState } from "react";
import type { AudioSource, DahliaAPI } from "../shared/types.js";

declare global {
  interface Window {
    dahlia: DahliaAPI;
  }
}

export const api = window.dahlia;

type Capture = { recordingId: string; stop(): Promise<void>; systemAvailable: boolean };

/** The Mac's audio output, or undefined when it is unavailable (recording continues with the microphone). */
async function systemAudio(): Promise<MediaStream | undefined> {
  try {
    const display = await navigator.mediaDevices.getDisplayMedia({ audio: true, video: true });
    // Only the audio is wanted; the screen track exists because getDisplayMedia requires one.
    for (const track of display.getVideoTracks()) track.stop();
    if (display.getAudioTracks().length > 0) return display;
    for (const track of display.getTracks()) track.stop();
  } catch {
    // The status bar says so.
  }
  return undefined;
}

export async function startCapture(recordingId: string, system: MediaStream | undefined, onLevel: (source: AudioSource, level: number) => void, onEnded: () => void): Promise<Capture> {
  // Chromium resamples every input to the context's rate, so the worklet only converts and batches.
  const context = new AudioContext({ sampleRate: 16_000 });
  const streams: MediaStream[] = [];
  const nodes: AudioWorkletNode[] = [];
  let stopping: Promise<void> | undefined;
  try {
    await context.audioWorklet.addModule("/pcm-worklet.js");
    streams.push(await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: false }, video: false }));
    if (system) streams.push(system);
    for (const stream of streams) for (const track of stream.getAudioTracks()) {
      track.addEventListener("ended", onEnded, { once: true });
      if (track.readyState === "ended") throw new Error("Capture track ended");
    }
    const systemAvailable = Boolean(system);
    const silence = context.createGain();
    silence.gain.value = 0;
    silence.connect(context.destination);
    streams.forEach((stream, index) => {
      const source: AudioSource = index === 0 ? "mic" : "system";
      const node = new AudioWorkletNode(context, "pcm-recorder", { channelCount: 1, channelCountMode: "explicit", channelInterpretation: "speakers" });
      node.port.onmessage = (event: MessageEvent<{ pcm?: ArrayBuffer; level?: number }>) => {
        if (event.data.pcm) api.recording.append(recordingId, source, event.data.pcm);
        if (event.data.level !== undefined) onLevel(source, event.data.level);
      };
      context.createMediaStreamSource(stream).connect(node);
      // Connected to the output (at zero gain) so the graph keeps pulling the worklet.
      node.connect(silence);
      nodes.push(node);
    });
    return {
      recordingId,
      systemAvailable,
      stop() {
        stopping ??= (async () => {
          // Send what each worklet still holds before the files close.
          const flushed = await Promise.allSettled(nodes.map((node) => new Promise<void>((resolve, reject) => {
            const previous = node.port.onmessage;
            const timer = setTimeout(() => reject(new Error("Capture flush timed out")), 1000);
            node.port.onmessage = (event: MessageEvent<{ flushed?: boolean }>) => {
              previous?.call(node.port, event);
              if (event.data.flushed) {
                clearTimeout(timer);
                resolve();
              }
            };
            node.port.postMessage("flush");
          })));
          for (const stream of streams) for (const track of stream.getTracks()) {
            track.removeEventListener("ended", onEnded);
            track.stop();
          }
          await context.close();
          if (flushed.some((result) => result.status === "rejected")) throw new Error("Capture flush failed");
        })();
        return stopping;
      },
    };
  } catch (error) {
    for (const stream of [...streams, ...(system ? [system] : [])]) for (const track of stream.getTracks()) {
      track.removeEventListener("ended", onEnded);
      track.stop();
    }
    await context.close();
    throw error;
  }
}

/** Loads with `load` and again whenever the main process reports a change; a stale response never wins. */
export function useLive<T>(load: () => Promise<T>, deps: unknown[]): T | undefined {
  const [value, setValue] = useState<T>();
  useEffect(() => {
    let generation = 0;
    let mounted = true;
    const run = () => {
      const current = ++generation;
      void load().then((next) => {
        if (mounted && current === generation) setValue(next);
      });
    };
    run();
    const off = api.onChange(run);
    return () => {
      mounted = false;
      off();
    };
    // The caller lists what `load` depends on.
  }, deps);
  return value;
}

const silentWarningMs = 30_000;

export function useRecorder() {
  const state = useLive(() => api.recording.state(), []);
  const capture = useRef<Capture | undefined>(undefined);
  const startingTask = useRef<Promise<void> | undefined>(undefined);
  const stoppingTask = useRef<Promise<void> | undefined>(undefined);
  const [levels, setLevels] = useState<Record<AudioSource, number>>({ mic: 0, system: 0 });
  const [systemAvailable, setSystemAvailable] = useState(true);
  const [systemSilentSince, setSystemSilentSince] = useState<number>();
  const [error, setError] = useState<string>();
  const [starting, setStarting] = useState(false);

  const stop = useCallback((error?: "captureEnded" | "captureFailed") => {
    if (stoppingTask.current) return stoppingTask.current;
    const task = (async () => {
      // Quit or a track ending can arrive while permissions/worklet setup are still pending.
      await startingTask.current;
      const current = capture.current;
      if (!current) return;
      try {
        await current.stop();
      } catch {
        error ??= "captureFailed";
      }
      capture.current = undefined;
      if (error) setError(error);
      await api.recording.stop(current.recordingId, error);
      setLevels({ mic: 0, system: 0 });
    })().finally(() => { stoppingTask.current = undefined; });
    stoppingTask.current = task;
    return task;
  }, []);

  const start = useCallback((meetingId: string) => {
    if (capture.current || startingTask.current || stoppingTask.current) return Promise.resolve();
    setStarting(true);
    setError(undefined);
    const task = (async () => {
      // First, while the click or shortcut still counts as user activation, which display capture may require.
      const system = await systemAudio();
      try {
        const active = await api.recording.start(meetingId);
        try {
          capture.current = await startCapture(active.recordingId, system, (source, level) => {
            setLevels((previous) => ({ ...previous, [source]: level }));
            if (source === "system") setSystemSilentSince((since) => (level > 0 ? undefined : since ?? Date.now()));
          }, () => { void stop("captureEnded"); });
          const state = await api.recording.state();
          if (state.active?.recordingId !== active.recordingId) {
            const current = capture.current;
            capture.current = undefined;
            await current?.stop();
            return;
          }
          setSystemAvailable(capture.current.systemAvailable);
          setSystemSilentSince(Date.now());
        } catch {
          await api.recording.stop(active.recordingId, "captureFailed");
          setError("microphoneUnavailable");
        }
      } catch (reason) {
        for (const track of system?.getTracks() ?? []) track.stop();
        setError(reason instanceof Error ? reason.message : String(reason));
      }
    })().finally(() => {
      startingTask.current = undefined;
      setStarting(false);
    });
    startingTask.current = task;
    return task;
  }, [stop]);

  useEffect(() => api.recording.onStopRequested(() => { void stop(); }), [stop]);

  // The main process closed the recording on its own (a failed write, a reload): stop capturing too.
  useEffect(() => {
    const current = capture.current;
    if (state && current && !stoppingTask.current && state.active?.recordingId !== current.recordingId) {
      capture.current = undefined;
      void current.stop().catch(() => { setError("captureFailed"); });
      setLevels({ mic: 0, system: 0 });
    }
  }, [state]);

  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!state?.active) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [state?.active]);

  return {
    active: state?.active,
    error: error ?? state?.error,
    starting,
    levels,
    elapsedMs: state?.active ? Math.max(0, now - state.active.startedAt) : 0,
    systemWarning: !state?.active ? undefined
      : !systemAvailable ? "systemUnavailable" as const
      : systemSilentSince !== undefined && now - systemSilentSince > silentWarningMs ? "systemSilent" as const : undefined,
    start,
    stop,
  };
}

export type Recorder = ReturnType<typeof useRecorder>;
