export type LogLevel = "info" | "warn" | "error";
/** Bounded event codes, counts, status codes and upstream request IDs only; never user content, credentials or paths. */
export type LogFields = Record<string, string | number | boolean | undefined>;

interface LogSink { log(level: LogLevel, event: string, fields: LogFields): void }
let sink: LogSink | undefined;

/** Also routes this process's server logs through the OTel service; undefined keeps console-only logging. */
export function setLogSink(next: LogSink | undefined): void {
  sink = next;
}

export function log(level: LogLevel, event: string, fields: LogFields = {}): void {
  console[level](JSON.stringify({ level, event, ...fields }));
  sink?.log(level, event, fields);
}
