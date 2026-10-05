import type { AppConfig, DatabricksWorkspaceConfig, OtelConfig, OtlpTarget } from "../config";
import { DatabricksTokenProvider, tokenUntilAborted } from "../databricks/token";
import { RequestError } from "../storage/upload";
import { log, type LogFields, type LogLevel } from "./log";
import { anyValue, logsProtobuf, OTLP_SIGNALS, otlpJsonToProtobuf, otlpResponseJson, otlpResponseProtobuf, type OtlpLogRecord, type OtlpSignal } from "./otlp";

export const OTLP_MAX_REQUEST_BYTES = 4 * 1024 * 1024;
/** Decompressed protobuf is forwarded without parsing; OTLP/JSON keeps the wire limit because it is parsed synchronously. */
const OTLP_MAX_DECODED_PROTOBUF_BYTES = 16 * 1024 * 1024;
/** Upstream Export*ServiceResponse bodies carry only partial_success; a larger body is treated as an empty response. */
const OTLP_MAX_RESPONSE_BYTES = 64 * 1024;
const EXPORT_TIMEOUT_MS = 30_000;
const LOG_BATCH = 100;
const LOG_BUFFER_LIMIT = 1_000;
const LOG_FLUSH_MS = 5_000;
const SHUTDOWN_FLUSH_MS = 5_000;
const SEVERITY = { info: [9, "INFO"], warn: [13, "WARN"], error: [17, "ERROR"] } as const;

/**
 * Sends one binary Export*ServiceRequest; `cancel` aborts it, including a pending token wait. Resolves to the upstream
 * Export*ServiceResponse protobuf, which carries any partial_success.
 */
export interface OtlpExporter {
  export(signal: OtlpSignal, body: Uint8Array<ArrayBuffer>, cancel?: AbortSignal): Promise<Uint8Array<ArrayBuffer>>;
}

export class OtelExportError extends Error {
  constructor(readonly status?: number) { super("otel_export_failed"); }
}

/** Reads a stream into memory, or returns undefined after cancelling it once it exceeds `limit` bytes. */
async function readAtMost(stream: ReadableStream<Uint8Array<ArrayBuffer>>, limit: number): Promise<Uint8Array<ArrayBuffer> | undefined> {
  const reader = stream.getReader();
  const chunks: Uint8Array<ArrayBuffer>[] = [];
  let length = 0;
  for (let next = await reader.read(); !next.done; next = await reader.read()) {
    length += next.value.length;
    if (length > limit) {
      await reader.cancel();
      return undefined;
    }
    chunks.push(next.value);
  }
  return new Uint8Array(await new Blob(chunks).arrayBuffer());
}

/** Databricks Zerobus requires an OAuth token whose `authorization_details` name the target table. */
function zerobusTokenProvider(workspace: DatabricksWorkspaceConfig, { workspaceId, table }: NonNullable<OtlpTarget["zerobus"]>, transport: typeof fetch) {
  const [catalog, schema] = table.split(".");
  return new DatabricksTokenProvider(workspace, transport, {
    resource: `api://databricks/workspaces/${workspaceId}/zerobusDirectWriteApi`,
    authorization_details: JSON.stringify([
      { type: "unity_catalog_privileges", privileges: ["USE CATALOG"], object_type: "CATALOG", object_full_path: catalog },
      { type: "unity_catalog_privileges", privileges: ["USE SCHEMA"], object_type: "SCHEMA", object_full_path: `${catalog}.${schema}` },
      { type: "unity_catalog_privileges", privileges: ["SELECT", "MODIFY"], object_type: "TABLE", object_full_path: table },
    ]),
  });
}

/** OTLP/HTTP protobuf to the configured endpoint of each signal, like a standard OpenTelemetry exporter. */
export function createOtlpExporter(settings: OtelConfig, workspace?: DatabricksWorkspaceConfig, transport: typeof fetch = fetch): OtlpExporter {
  const tokens: Partial<Record<OtlpSignal, DatabricksTokenProvider>> = {};
  for (const signal of OTLP_SIGNALS) {
    const zerobus = settings.exporters[signal]?.zerobus;
    if (zerobus) tokens[signal] = zerobusTokenProvider(workspace!, zerobus, transport);
  }
  return {
    async export(signal, body, cancel) {
      const target = settings.exporters[signal]!;
      const timeout = AbortSignal.timeout(EXPORT_TIMEOUT_MS);
      const abort = cancel ? AbortSignal.any([timeout, cancel]) : timeout;
      const provider = tokens[signal];
      let response: Response;
      try {
        const token = provider && await tokenUntilAborted(provider, abort);
        response = await transport(target.url, {
          method: "POST",
          headers: { ...target.headers, ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/x-protobuf" },
          body,
          signal: abort,
        });
      } catch {
        throw new OtelExportError();
      }
      if (!response.ok) {
        await response.body?.cancel();
        throw new OtelExportError(response.status);
      }
      // The batch is accepted once upstream answers 2xx; an unreadable response body only loses partial_success details.
      const result = response.body && await readAtMost(response.body, OTLP_MAX_RESPONSE_BYTES).catch(() => undefined);
      return result ?? new Uint8Array();
    },
  };
}

async function decompress(encoding: string | null, bytes: Uint8Array<ArrayBuffer>, limit: number): Promise<Uint8Array<ArrayBuffer>> {
  const value = encoding?.trim().toLowerCase();
  if (!value || value === "identity") return bytes;
  if (value !== "gzip") throw new RequestError(415, "unsupported_content_encoding");
  let decoded: Uint8Array<ArrayBuffer> | undefined;
  try {
    decoded = await readAtMost(new Response(bytes).body!.pipeThrough(new DecompressionStream("gzip")), limit);
  } catch {
    throw new RequestError(400, "invalid_otlp_request");
  }
  if (!decoded) throw new RequestError(413, "request_too_large");
  return decoded;
}

/** OTLP/HTTP receiver that forwards to the configured exporter, which also receives Server logs. */
export class OtelService {
  private logs: OtlpLogRecord[] = [];
  /** Records encoded into batches that are queued or in flight. */
  private queued = 0;
  /** Aborted by shutdown: cancels the in-flight log export and skips queued batches. */
  private readonly closing = new AbortController();
  private timer?: ReturnType<typeof setTimeout>;
  private flushing = Promise.resolve();

  constructor(
    private readonly exporter: OtlpExporter,
    /** Signals with a configured endpoint; others have no receiver route and Server logs stay on the console. */
    readonly signals: readonly OtlpSignal[] = OTLP_SIGNALS,
    private readonly serviceName = "dahlia-server",
  ) {}

  /**
   * Handles an OTLP/HTTP request body (binary protobuf or JSON, optionally gzip) and returns the upstream OTLP response.
   * `cancel` is the request's signal, so a disconnected sender or a closing server aborts the forward.
   */
  async receive(signal: OtlpSignal, headers: Headers, body: ArrayBuffer, cancel?: AbortSignal): Promise<Response> {
    const type = headers.get("content-type")?.split(";")[0]!.trim().toLowerCase();
    const json = type === "application/json";
    if (!json && type !== "application/x-protobuf" && type !== "application/protobuf") throw new RequestError(415, "unsupported_media_type");
    let payload = await decompress(headers.get("content-encoding"), new Uint8Array(body), json ? OTLP_MAX_REQUEST_BYTES : OTLP_MAX_DECODED_PROTOBUF_BYTES);
    try {
      if (json) payload = otlpJsonToProtobuf(signal, new TextDecoder().decode(payload));
    } catch {
      throw new RequestError(400, "invalid_otlp_request");
    }
    let result: Uint8Array<ArrayBuffer>;
    try {
      result = await this.exporter.export(signal, payload, cancel);
    } catch (error) {
      const status = error instanceof OtelExportError ? error.status : undefined;
      // Log every upstream failure: a 400 may come from the Server's endpoint, headers or table rather than the payload.
      log("warn", "otel_export_failed", { signal, status });
      // Protobuf is forwarded unparsed, so the upstream 400 is the only payload validation and stays non-retryable.
      throw status === 400 ? new RequestError(400, "invalid_otlp_request") : new RequestError(503, "otel_unavailable");
    }
    // Relay the upstream response so senders see partial_success, in the encoding of their request.
    return json ? Response.json(otlpResponseJson(signal, result))
      : new Response(otlpResponseProtobuf(signal, result), { headers: { "content-type": "application/x-protobuf" } });
  }

  /** Buffers one server log record when logs are exported; export is best-effort and never awaited by the caller. */
  log(level: LogLevel, event: string, fields: LogFields): void {
    // ponytail: drops new records while the endpoint is unreachable; add a disk spool only if server logs become audit data.
    if (!this.signals.includes("logs") || this.closing.signal.aborted || this.logs.length + this.queued >= LOG_BUFFER_LIMIT) return;
    const [severityNumber, severityText] = SEVERITY[level];
    this.logs.push({
      timeUnixNano: BigInt(Date.now()) * 1_000_000n, severityNumber, severityText, eventName: event, body: anyValue(event),
      attributes: Object.entries(fields).flatMap(([key, value]) => value === undefined ? [] : [{ key, value: anyValue(value) }]),
    });
    if (this.logs.length >= LOG_BATCH) void this.flush();
    else if (!this.timer) {
      this.timer = setTimeout(() => void this.flush(), LOG_FLUSH_MS);
      (this.timer as { unref?: () => void }).unref?.();
    }
  }

  /** Exports buffered server logs; resolves after every earlier flush settles. */
  flush(): Promise<void> {
    clearTimeout(this.timer);
    this.timer = undefined;
    const records = this.logs.splice(0);
    if (!records.length) return this.flushing;
    const body = logsProtobuf(this.serviceName, records);
    this.queued += records.length;
    // Report export failures to the console only, so a failing endpoint cannot feed its own log buffer.
    this.flushing = this.flushing.then(async () => { if (!this.closing.signal.aborted) await this.exporter.export("logs", body, this.closing.signal); })
      .catch((error: unknown) => console.warn(JSON.stringify({ level: "warn", event: "otel_log_export_failed",
        status: error instanceof OtelExportError ? error.status : undefined })))
      .finally(() => { this.queued -= records.length; });
    return this.flushing;
  }

  /**
   * Flushes for at most SHUTDOWN_FLUSH_MS, then cancels the in-flight export and drops queued batches and later
   * records, so a stalled endpoint cannot keep the process alive. A token request already sent to Databricks keeps
   * its own 30 s timeout.
   */
  async shutdown(): Promise<void> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([this.flush(), new Promise<void>((resolve) => { timer = setTimeout(resolve, SHUTDOWN_FLUSH_MS); })]);
    clearTimeout(timer);
    this.closing.abort();
  }
}

export function createOtel(config: AppConfig, transport?: typeof fetch): OtelService | undefined {
  const settings = config.otel;
  return settings && new OtelService(createOtlpExporter(settings, config.databricksWorkspace, transport),
    OTLP_SIGNALS.filter((signal) => settings.exporters[signal]), settings.serviceName);
}
