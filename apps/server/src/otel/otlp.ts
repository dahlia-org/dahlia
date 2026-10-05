import { create, fromJson, toBinary, type JsonValue, type MessageInitShape } from "@bufbuild/protobuf";
import { ExportLogsServiceRequestSchema } from "./gen/opentelemetry/proto/collector/logs/v1/logs_service_pb";
import { ExportMetricsServiceRequestSchema } from "./gen/opentelemetry/proto/collector/metrics/v1/metrics_service_pb";
import { ExportTraceServiceRequestSchema } from "./gen/opentelemetry/proto/collector/trace/v1/trace_service_pb";
import type { AnyValueSchema } from "./gen/opentelemetry/proto/common/v1/common_pb";
import type { LogRecordSchema } from "./gen/opentelemetry/proto/logs/v1/logs_pb";

export const OTLP_SIGNALS = ["traces", "logs", "metrics"] as const;
export type OtlpSignal = typeof OTLP_SIGNALS[number];
export type OtlpLogRecord = MessageInitShape<typeof LogRecordSchema>;

export class OtlpError extends Error {}

const requests = { traces: ExportTraceServiceRequestSchema, logs: ExportLogsServiceRequestSchema, metrics: ExportMetricsServiceRequestSchema };
// OTLP/JSON writes trace and span IDs as hex, unlike the protobuf JSON mapping's base64 bytes.
const ID_FIELDS = new Set(["traceId", "spanId", "parentSpanId", "trace_id", "span_id", "parent_span_id"]);

function base64Ids(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(base64Ids);
  if (typeof value !== "object" || value === null) return value;
  return Object.fromEntries(Object.entries(value).map(([key, field]) => {
    if (!ID_FIELDS.has(key) || typeof field !== "string") return [key, base64Ids(field)];
    if (!/^(?:[0-9a-f]{2})*$/i.test(field)) throw new OtlpError("invalid OTLP ID");
    return [key, btoa(String.fromCharCode(...(field.match(/../g) ?? []).map((pair) => parseInt(pair, 16))))];
  }));
}

/** Encodes an OTLP/JSON Export*ServiceRequest as binary protobuf; unknown fields are ignored. */
export function otlpJsonToProtobuf(signal: OtlpSignal, json: string): Uint8Array<ArrayBuffer> {
  try {
    const schema = requests[signal];
    return toBinary(schema, fromJson(schema, base64Ids(JSON.parse(json)) as JsonValue, { ignoreUnknownFields: true }));
  } catch (error) {
    throw error instanceof OtlpError ? error : new OtlpError("invalid OTLP JSON");
  }
}

export function anyValue(value: string | number | boolean): MessageInitShape<typeof AnyValueSchema> {
  if (typeof value === "string") return { value: { case: "stringValue", value } };
  if (typeof value === "boolean") return { value: { case: "boolValue", value } };
  return Number.isSafeInteger(value) ? { value: { case: "intValue", value: BigInt(value) } } : { value: { case: "doubleValue", value } };
}

/** Encodes log records of one service as an ExportLogsServiceRequest. */
export function logsProtobuf(serviceName: string, logRecords: OtlpLogRecord[]): Uint8Array<ArrayBuffer> {
  return toBinary(ExportLogsServiceRequestSchema, create(ExportLogsServiceRequestSchema, { resourceLogs: [{
    resource: { attributes: [{ key: "service.name", value: anyValue(serviceName) }] },
    scopeLogs: [{ scope: { name: serviceName }, logRecords }],
  }] }));
}
