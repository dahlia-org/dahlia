/** `HH:MM:SS` for a time in milliseconds, as transcript references are written. */
export function timestamp(ms: number) {
  const total = Math.max(0, Math.floor(ms / 1000));
  return [Math.floor(total / 3600), Math.floor(total / 60) % 60, total % 60].map((part) => String(part).padStart(2, "0")).join(":");
}

/** Milliseconds for an `HH:MM:SS` reference. */
export function referenceMs(reference: string) {
  const [hours = 0, minutes = 0, seconds = 0] = reference.split(":").map(Number);
  return ((hours * 60 + minutes) * 60 + seconds) * 1000;
}
