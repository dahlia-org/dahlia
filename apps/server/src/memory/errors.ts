export class HindsightError extends Error {
  constructor(readonly code: string, readonly status?: number) { super(code); }
}
