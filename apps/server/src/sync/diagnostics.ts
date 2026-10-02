/** Opt-in, process-local timing samples for tests and profiling; never sent to telemetry. */
export type SyncTimingPhase = "connectionAndBegin" | "transaction" | "authorizationLock" | "workspaceLock" | "domainLock" | "documentLock" | "notesLock" | "resourceLock" | "publicationLock";
const captures = new Set<Map<SyncTimingPhase, number[]>>();

export function beginSyncTiming(phase: SyncTimingPhase): () => void {
  if (!captures.size) return () => {};
  const targets = [...captures], started = performance.now();
  let finished = false;
  return () => {
    if (finished) return;
    finished = true;
    const elapsed = performance.now() - started;
    for (const target of targets) {
      if (!captures.has(target)) continue;
      const samples = target.get(phase) ?? [];
      if (samples.length === 128) samples.shift();
      samples.push(elapsed);
      target.set(phase, samples);
    }
  };
}

/** Internal profiling hook. Fixed phase names and durations are the only retained data. */
export function captureSyncTimings() {
  const samples = new Map<SyncTimingPhase, number[]>();
  captures.add(samples);
  return {
    stop() {
      captures.delete(samples);
      return Object.fromEntries([...samples].map(([phase, values]) => {
        const sorted = values.toSorted((a, b) => a - b);
        return [phase, { count: sorted.length, p50: sorted[Math.ceil(sorted.length * .5) - 1], p95: sorted[Math.ceil(sorted.length * .95) - 1] }];
      }));
    },
  };
}
