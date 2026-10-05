import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { fromBinary, toJson } from "@bufbuild/protobuf";
import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { createNodeApplicationStore } from "../src/auth/node-store";
import { loadConfig, type AppConfig } from "../src/config";
import { createWorkerHandler } from "../src/worker";
import { ExportLogsServiceRequestSchema } from "../src/otel/gen/opentelemetry/proto/collector/logs/v1/logs_service_pb";
import { ExportMetricsServiceRequestSchema } from "../src/otel/gen/opentelemetry/proto/collector/metrics/v1/metrics_service_pb";
import { ExportTraceServiceRequestSchema } from "../src/otel/gen/opentelemetry/proto/collector/trace/v1/trace_service_pb";
import { log, setLogSink } from "../src/otel/log";
import { OtlpError, otlpJsonToProtobuf } from "../src/otel/otlp";
import { createOtel, createOtlpExporter, OtelExportError, OtelService, type OtlpExporter } from "../src/otel/service";
import { seedHeaderIdentity, testUserID } from "./public-test-client";

const traceId = "5b8efff798038103d269b633813fc60c";
const resource = { attributes: [{ key: "service.name", value: { stringValue: "dahlia-desktop" } }] };
const traces = { resourceSpans: [{ resource, scopeSpans: [{ scope: { name: "dahlia", version: "1.0.0" }, spans: [{
  traceId, spanId: "eee19b7ec3c1b174", parentSpanId: "eee19b7ec3c1b173", flags: 257, name: "sync", kind: 2,
  startTimeUnixNano: "1759622400000000000", endTimeUnixNano: "1759622400500000000",
  attributes: [{ key: "count", value: { intValue: "-3" } }, { key: "raw", value: { bytesValue: "AAEC" } }],
  links: [{ traceId, spanId: "eee19b7ec3c1b172" }], status: { message: "failed", code: 2 },
}] }] }] };
const hex = (value: string) => Uint8Array.from(value.match(/../g)!, (pair) => parseInt(pair, 16));
const protobuf = { "content-type": "application/x-protobuf" };

describe("OTLP/JSON transcoding", () => {
  it("encodes hex IDs, 64-bit strings and integer enums as protobuf", () => {
    const span = fromBinary(ExportTraceServiceRequestSchema, otlpJsonToProtobuf("traces", JSON.stringify(traces))).resourceSpans[0]!.scopeSpans[0]!.spans[0]!;
    expect([span.traceId, span.spanId, span.parentSpanId, span.links[0]!.spanId]).toEqual(["5b8efff798038103d269b633813fc60c", "eee19b7ec3c1b174",
      "eee19b7ec3c1b173", "eee19b7ec3c1b172"].map(hex));
    expect([span.startTimeUnixNano, span.kind, span.flags, span.status?.code]).toEqual([1759622400000000000n, 2, 257, 2]);
    expect(span.attributes.map(({ value }) => value?.value)).toEqual([{ case: "intValue", value: -3n }, { case: "bytesValue", value: Uint8Array.of(0, 1, 2) }]);

    const logs = { resourceLogs: [{ scopeLogs: [{ logRecords: [{ timeUnixNano: "1", severityNumber: 17, traceId, body: { stringValue: "upload_failed" } }] }] }] };
    expect(toJson(ExportLogsServiceRequestSchema, fromBinary(ExportLogsServiceRequestSchema, otlpJsonToProtobuf("logs", JSON.stringify(logs)))))
      .toMatchObject({ resourceLogs: [{ scopeLogs: [{ logRecords: [{ timeUnixNano: "1", severityNumber: "SEVERITY_NUMBER_ERROR", body: { stringValue: "upload_failed" } }] }] }] });
    const metrics = { resourceMetrics: [{ scopeMetrics: [{ metrics: [{ name: "latency", histogram: { dataPoints: [{ count: "3", bucketCounts: ["1", "2"],
      exemplars: [{ traceId, asInt: "-1" }] }], aggregationTemporality: 1 } }] }] }] };
    const point = fromBinary(ExportMetricsServiceRequestSchema, otlpJsonToProtobuf("metrics", JSON.stringify(metrics))).resourceMetrics[0]!.scopeMetrics[0]!.metrics[0]!;
    expect(point.data.case === "histogram" && [point.data.value.dataPoints[0]!.bucketCounts, point.data.value.dataPoints[0]!.exemplars[0]!.traceId])
      .toEqual([[1n, 2n], hex(traceId)]);
  });

  it("matches the opentelemetry-proto wire format and ignores unknown fields", () => {
    const span = [0x0a, 16, ...Array.from({ length: 16 }, (_, index) => index + 1), 0x2a, 1, 0x61, 0x39, 1, 0, 0, 0, 0, 0, 0, 0];
    const request = { resourceSpans: [{ scopeSpans: [{ spans: [{ traceId: "0102030405060708090a0b0c0d0e0f10", name: "a", startTimeUnixNano: "1", future: true }] }] }] };
    expect(otlpJsonToProtobuf("traces", JSON.stringify(request))).toEqual(Uint8Array.from([0x0a, span.length + 4, 0x12, span.length + 2, 0x12, span.length, ...span]));
  });

  it("rejects malformed OTLP/JSON", () => {
    for (const span of [{ traceId: "xyz" }, { startTimeUnixNano: "1.5" }, { attributes: {} }, { name: 1 }]) {
      expect(() => otlpJsonToProtobuf("traces", JSON.stringify({ resourceSpans: [{ scopeSpans: [{ spans: [span] }] }] }))).toThrow(OtlpError);
    }
    expect(() => otlpJsonToProtobuf("traces", "not json")).toThrow(OtlpError);
  });
});

describe("OTLP/HTTP receiver", () => {
  it("authenticates, validates and forwards protobuf, gzip and JSON requests on Node and Workers", async () => {
    const directory = mkdtempSync(join(tmpdir(), "dahlia-otlp-"));
    const path = join(directory, "server.sqlite");
    const config: AppConfig = { authProvider: "header", authHeader: "X-Forwarded-Email", databaseType: "sqlite", databaseUrl: `file:${path}`,
      baseUrl: "http://localhost:5173", oauthRedirectUris: [], maxRequestBytes: 1048576 };
    const store = createNodeApplicationStore(config);
    const exported: [string, Uint8Array][] = [];
    let upstream: number | undefined;
    const cancels: (AbortSignal | undefined)[] = [];
    const exporter: OtlpExporter = { async export(signal, body, cancel) {
      cancels.push(cancel);
      if (upstream) throw new OtelExportError(upstream);
      exported.push([signal, body]);
    } };
    try {
      await store.migrate();
      await seedHeaderIdentity(store, path, { userId: testUserID("owner"), email: "owner@example.com", source: "header" });
      const app = createApp({ config, authStore: store, otel: new OtelService(exporter) });
      const identity = { "x-forwarded-email": "owner@example.com", "x-forwarded-user": "owner" };
      const post = (signal: string, body: BodyInit, headers: Record<string, string>, authenticated = true) => app.request(`/api/v1/${signal}`, {
        method: "POST", body, headers: { ...(authenticated ? identity : {}), ...headers },
      });
      const bytes = otlpJsonToProtobuf("traces", JSON.stringify(traces));
      const accepted = await post("traces", bytes, protobuf);
      expect([accepted.status, accepted.headers.get("content-type"), (await accepted.arrayBuffer()).byteLength]).toEqual([200, "application/x-protobuf", 0]);
      expect((await post("metrics", gzipSync(bytes), { ...protobuf, "content-encoding": "gzip" })).status).toBe(200);
      const json = await post("logs", JSON.stringify({ resourceLogs: [] }), { "content-type": "application/json; charset=utf-8" });
      expect([json.status, await json.json()]).toEqual([200, {}]);
      const worker = createWorkerHandler(async () => app);
      const fetchWorker = worker.fetch!.bind(worker) as unknown as (request: Request, env: Cloudflare.Env, context: ExecutionContext) => Promise<Response>;
      expect((await fetchWorker(new Request(`${config.baseUrl}/api/v1/traces`, { method: "POST", body: JSON.stringify(traces),
        headers: { ...identity, "content-type": "application/json" } }), {} as Cloudflare.Env, {} as ExecutionContext)).status).toBe(200);
      // The forward is cancelled with the request.
      expect(cancels.every((cancel) => cancel instanceof AbortSignal)).toBe(true);
      // Protobuf passes through unchanged; OTLP/JSON is transcoded to the same payload.
      expect(exported).toEqual([["traces", bytes], ["metrics", bytes], ["logs", new Uint8Array()], ["traces", bytes]]);

      expect((await post("traces", "{}", { "content-type": "text/plain" })).status).toBe(415);
      expect((await post("traces", "{}", { "content-type": "application/json", "content-encoding": "br" })).status).toBe(415);
      expect((await post("traces", "not json", { "content-type": "application/json" })).status).toBe(400);
      expect((await post("traces", "not gzip", { ...protobuf, "content-encoding": "gzip" })).status).toBe(400);
      expect((await post("traces", new Uint8Array(4 * 1024 * 1024 + 1), protobuf)).status).toBe(413);
      expect((await post("traces", gzipSync(new Uint8Array(16 * 1024 * 1024 + 1)), { ...protobuf, "content-encoding": "gzip" })).status).toBe(413);
      // Parsed OTLP/JSON keeps the wire limit after decompression; pass-through protobuf may expand further.
      expect((await post("traces", gzipSync(`${" ".repeat(4 * 1024 * 1024)}{}`), { "content-type": "application/json", "content-encoding": "gzip" })).status).toBe(413);
      expect((await post("metrics", gzipSync(new Uint8Array(5 * 1024 * 1024)), { ...protobuf, "content-encoding": "gzip" })).status).toBe(200);
      expect(exported.at(-1)![1]).toHaveLength(5 * 1024 * 1024);
      exported.pop();
      expect((await post("traces", "{}", { "content-type": "application/json" }, false)).status).toBe(401);
      expect((await app.request("/api/v1/traces", { headers: identity })).status).toBe(405);
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      try {
        upstream = 400;
        expect((await post("traces", bytes, protobuf)).status).toBe(400);
        expect(warn).toHaveBeenCalledWith(JSON.stringify({ level: "warn", event: "otel_export_failed", signal: "traces", status: 400 }));
        upstream = 403;
        expect((await post("traces", bytes, protobuf)).status).toBe(503);
        expect(warn).toHaveBeenCalledWith(JSON.stringify({ level: "warn", event: "otel_export_failed", signal: "traces", status: 403 }));
      } finally { warn.mockRestore(); }

      // Without a backend the routes do not exist.
      expect((await createApp({ config, authStore: store }).request("/api/v1/traces", { method: "POST", body: bytes, headers: { ...identity, ...protobuf } })).status).toBe(404);
    } finally {
      await store.close?.();
      rmSync(directory, { recursive: true, force: true });
    }
  });
});

describe("OTLP exporter", () => {
  const databricks = { DAHLIA_AUTH_TYPE: "header", DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "client",
    DATABRICKS_CLIENT_SECRET: "secret", DAHLIA_OTEL_AUTH: "databricks", OTEL_EXPORTER_OTLP_ENDPOINT: "https://1234.zerobus.us-west-2.cloud.databricks.com",
    OTEL_EXPORTER_OTLP_TRACES_HEADERS: "x-databricks-zerobus-table-name=dahlia.ops.dahlia_otel_spans",
    OTEL_EXPORTER_OTLP_LOGS_HEADERS: "x-databricks-zerobus-table-name=dahlia.ops.dahlia_otel_logs",
    OTEL_EXPORTER_OTLP_METRICS_HEADERS: "x-databricks-zerobus-table-name=dahlia.ops.dahlia_otel_metrics" };

  it("sends to the standard endpoint with the configured headers", async () => {
    const transport = vi.fn<typeof fetch>(async () => new Response(null));
    const config = loadConfig({ DAHLIA_AUTH_TYPE: "header", OTEL_EXPORTER_OTLP_ENDPOINT: "https://clickstack.example:4318/otlp/",
      OTEL_EXPORTER_OTLP_HEADERS: "authorization=ingestion-key", OTEL_EXPORTER_OTLP_LOGS_HEADERS: "authorization=logs-key,content-type=text/plain" });
    const exporter = createOtlpExporter(config.otel!, undefined, transport);
    const body = otlpJsonToProtobuf("traces", JSON.stringify(traces));
    await exporter.export("traces", body);
    await exporter.export("logs", body);
    const calls = transport.mock.calls as unknown as [string, RequestInit][];
    expect(calls.map(([url, request]) => [url, Object.fromEntries(new Headers(request.headers)), request.body])).toEqual([
      ["https://clickstack.example:4318/otlp/v1/traces", { authorization: "ingestion-key", "content-type": "application/x-protobuf" }, body],
      ["https://clickstack.example:4318/otlp/v1/logs", { authorization: "logs-key", "content-type": "application/x-protobuf" }, body],
    ]);
  });

  it("adds a Zerobus table-scoped service-principal token with DAHLIA_OTEL_AUTH=databricks", async () => {
    const transport = vi.fn<typeof fetch>(async (input) => String(input).endsWith("/oidc/v1/token")
      ? Response.json({ access_token: "zerobus-token", expires_in: 3600 }) : new Response(null));
    const config = loadConfig(databricks);
    const exporter = createOtlpExporter(config.otel!, config.databricksWorkspace, transport);
    const body = otlpJsonToProtobuf("traces", JSON.stringify(traces));
    await exporter.export("traces", body);
    await exporter.export("traces", body);
    const calls = transport.mock.calls as unknown as [string, RequestInit][];
    expect(calls).toHaveLength(3);
    const form = new URLSearchParams(String(calls[0]![1].body));
    expect([String(calls[0]![0]), form.get("grant_type"), form.get("scope"), form.get("resource")]).toEqual(["https://workspace.example/oidc/v1/token",
      "client_credentials", "all-apis", "api://databricks/workspaces/1234/zerobusDirectWriteApi"]);
    expect(JSON.parse(form.get("authorization_details")!)).toEqual([
      { type: "unity_catalog_privileges", privileges: ["USE CATALOG"], object_type: "CATALOG", object_full_path: "dahlia" },
      { type: "unity_catalog_privileges", privileges: ["USE SCHEMA"], object_type: "SCHEMA", object_full_path: "dahlia.ops" },
      { type: "unity_catalog_privileges", privileges: ["SELECT", "MODIFY"], object_type: "TABLE", object_full_path: "dahlia.ops.dahlia_otel_spans" },
    ]);
    const [url, request] = calls[1]!;
    expect(url).toBe("https://1234.zerobus.us-west-2.cloud.databricks.com/v1/traces");
    expect(Object.fromEntries(new Headers(request.headers))).toEqual({ authorization: "Bearer zerobus-token",
      "content-type": "application/x-protobuf", "x-databricks-zerobus-table-name": "dahlia.ops.dahlia_otel_spans" });
    expect(request.body).toBe(body);
  });

  it("exposes only signals with an endpoint", async () => {
    const otel = createOtel(loadConfig({ DAHLIA_AUTH_TYPE: "header", OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "http://collector:4318/v1/traces" }))!;
    expect(otel.signals).toEqual(["traces"]);
    const send = vi.fn(async () => {});
    const service = new OtelService({ export: send }, otel.signals);
    service.log("error", "request_failed", {});
    await service.flush();
    expect(send).not.toHaveBeenCalled();
    expect(createOtel(loadConfig({ DAHLIA_AUTH_TYPE: "header" }))).toBeUndefined();
  });
});

describe("server logs", () => {
  it("exports structured logs through the backend without blocking the caller", async () => {
    const bodies: Uint8Array[] = [];
    let fail = false;
    const service = new OtelService({ async export(signal, body) {
      expect(signal).toBe("logs");
      if (fail) throw new OtelExportError(429);
      bodies.push(body);
    } });
    const info = vi.spyOn(console, "info").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    setLogSink(service);
    try {
      log("info", "job_completed", { kind: "summary", durationMs: 12, ratio: 0.5, retryable: false, requestId: undefined });
      expect(info).toHaveBeenCalledWith(JSON.stringify({ level: "info", event: "job_completed", kind: "summary", durationMs: 12, ratio: 0.5, retryable: false }));
      await service.flush();
      fail = true;
      log("warn", "job_failed");
      await service.flush();
      expect(warn).toHaveBeenLastCalledWith(JSON.stringify({ level: "warn", event: "otel_log_export_failed", status: 429 }));
    } finally {
      setLogSink(undefined);
      info.mockRestore();
      warn.mockRestore();
    }
    expect(bodies).toHaveLength(1);
    expect(toJson(ExportLogsServiceRequestSchema, fromBinary(ExportLogsServiceRequestSchema, bodies[0]!))).toMatchObject({ resourceLogs: [{
      resource: { attributes: [{ key: "service.name", value: { stringValue: "dahlia-server" } }] },
      scopeLogs: [{ scope: { name: "dahlia-server" }, logRecords: [{ severityNumber: "SEVERITY_NUMBER_INFO", severityText: "INFO", eventName: "job_completed",
        body: { stringValue: "job_completed" }, attributes: [{ key: "kind", value: { stringValue: "summary" } }, { key: "durationMs", value: { intValue: "12" } },
          { key: "ratio", value: { doubleValue: 0.5 } }, { key: "retryable", value: { boolValue: false } }] }] }],
    }] });
  });

});

describe("server log queue", () => {
  const count = (body: Uint8Array) => fromBinary(ExportLogsServiceRequestSchema, body).resourceLogs[0]!.scopeLogs[0]!.logRecords.length;

  it("bounds buffered and queued records while the endpoint stalls", async () => {
    let release!: () => void;
    const stalled = new Promise<void>((resolve) => { release = resolve; });
    const bodies: Uint8Array[] = [];
    const service = new OtelService({ async export(_signal, body) { bodies.push(body); await stalled; } });
    for (let index = 0; index < 1_500; index++) service.log("info", "job_completed", { index });
    release();
    await service.flush();
    expect(bodies.reduce((total, body) => total + count(body), 0)).toBe(1_000);
    // Settled batches free capacity again.
    service.log("info", "job_completed", {});
    await service.flush();
    expect(count(bodies.at(-1)!)).toBe(1);
  });

  it("cancels the in-flight export and drops queued batches after the shutdown wait", async () => {
    vi.useFakeTimers();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const cancels: AbortSignal[] = [];
    const service = new OtelService({ export: (_signal, _body, cancel) => {
      cancels.push(cancel!);
      return new Promise<void>((_resolve, reject) => cancel!.addEventListener("abort", () => reject(new Error("aborted"))));
    } });
    try {
      for (let index = 0; index < 250; index++) service.log("info", "job_completed", { index });
      const shutdown = service.shutdown();
      await vi.advanceTimersByTimeAsync(5_000);
      await shutdown;
      await service.flush();
      expect(cancels).toHaveLength(1);
      expect(cancels[0]!.aborted).toBe(true);
      service.log("info", "after_shutdown", {});
      await service.flush();
      expect(cancels).toHaveLength(1);
    } finally {
      vi.useRealTimers();
      warn.mockRestore();
    }
  });

  it("aborts the HTTP export and the token wait when cancelled", async () => {
    const pending = (signal?: AbortSignal | null) => new Promise<Response>((_resolve, reject) =>
      signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError"))));
    const plain = createOtlpExporter(loadConfig({ DAHLIA_AUTH_TYPE: "header", OTEL_EXPORTER_OTLP_ENDPOINT: "http://collector:4318" }).otel!, undefined,
      vi.fn<typeof fetch>(async (_input, init) => pending(init?.signal)));
    const zerobus = loadConfig({ DAHLIA_AUTH_TYPE: "header", DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "client",
      DATABRICKS_CLIENT_SECRET: "secret", DAHLIA_OTEL_AUTH: "databricks", OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "https://1234.zerobus.example/v1/traces",
      OTEL_EXPORTER_OTLP_TRACES_HEADERS: "x-databricks-zerobus-table-name=dahlia.ops.dahlia_otel_spans" });
    const tokenStalled = createOtlpExporter(zerobus.otel!, zerobus.databricksWorkspace, vi.fn<typeof fetch>(async () => pending()));
    for (const [exporter, signal] of [[plain, "logs"], [tokenStalled, "traces"]] as const) {
      const cancel = new AbortController();
      const result = exporter.export(signal, new Uint8Array(), cancel.signal);
      cancel.abort();
      await expect(result).rejects.toBeInstanceOf(OtelExportError);
    }
  });
});

describe("OTel configuration", () => {
  const base = { DAHLIA_AUTH_TYPE: "header" };

  it("reads the standard OTLP exporter variables", () => {
    expect(loadConfig(base).otel).toBeUndefined();
    expect(loadConfig({ ...base, OTEL_EXPORTER_OTLP_ENDPOINT: " " }).otel).toBeUndefined();
    expect(loadConfig({ ...base, OTEL_EXPORTER_OTLP_ENDPOINT: "http://collector:4318", OTEL_EXPORTER_OTLP_PROTOCOL: "http/protobuf",
      OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: "https://metrics.example/ingest", OTEL_EXPORTER_OTLP_HEADERS: "Authorization=Basic%20a2V5, x-team = core",
      OTEL_EXPORTER_OTLP_METRICS_HEADERS: "x-team=metrics", OTEL_SERVICE_NAME: "dahlia-server-dev" }).otel).toEqual({
      serviceName: "dahlia-server-dev",
      exporters: {
        traces: { url: "http://collector:4318/v1/traces", headers: { authorization: "Basic a2V5", "x-team": "core" } },
        logs: { url: "http://collector:4318/v1/logs", headers: { authorization: "Basic a2V5", "x-team": "core" } },
        metrics: { url: "https://metrics.example/ingest", headers: { authorization: "Basic a2V5", "x-team": "metrics" } },
      },
    });
    expect(loadConfig({ ...base, OTEL_EXPORTER_OTLP_LOGS_ENDPOINT: "http://localhost:4318/v1/logs" }).otel?.serviceName).toBe("dahlia-server");
    for (const env of [{ OTEL_EXPORTER_OTLP_PROTOCOL: "grpc" }, { OTEL_EXPORTER_OTLP_TRACES_PROTOCOL: "http/json" }]) {
      expect(() => loadConfig({ ...base, OTEL_EXPORTER_OTLP_ENDPOINT: "http://collector:4318", ...env })).toThrow(/PROTOCOL must be http\/protobuf/);
    }
    for (const endpoint of ["ftp://collector", "https://user:secret@collector.example"]) {
      expect(() => loadConfig({ ...base, OTEL_EXPORTER_OTLP_ENDPOINT: endpoint })).toThrow(/HTTP\(S\) URL without credentials/);
    }
    expect(() => loadConfig({ ...base, OTEL_EXPORTER_OTLP_ENDPOINT: "http://collector:4318", OTEL_EXPORTER_OTLP_HEADERS: "token" })).toThrow(/key=value/);
  });

  it("requires Zerobus endpoints and table headers for Databricks authentication", () => {
    const databricks = { ...base, DATABRICKS_HOST: "https://workspace.example", DATABRICKS_CLIENT_ID: "client", DATABRICKS_CLIENT_SECRET: "secret",
      DAHLIA_OTEL_AUTH: "databricks", OTEL_EXPORTER_OTLP_TRACES_HEADERS: "x-databricks-zerobus-table-name=dahlia.ops.dahlia_otel_spans" };
    const config = loadConfig({ ...databricks, OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "https://1234.zerobus.us-west-2.cloud.databricks.com/v1/traces" });
    expect(config.otel?.exporters.traces?.zerobus).toEqual({ workspaceId: "1234", table: "dahlia.ops.dahlia_otel_spans" });
    expect(config.databricksWorkspace?.tokenUrl).toBe("https://workspace.example/oidc/v1/token");
    expect(loadConfig({ ...databricks }).otel).toBeUndefined();
    for (const endpoint of ["http://1234.zerobus.example/v1/traces", "https://collector.example/v1/traces"]) {
      expect(() => loadConfig({ ...databricks, OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: endpoint })).toThrow(/zerobus/);
    }
    for (const headers of ["x-databricks-zerobus-table-name=dahlia.ops", "x-other=1"]) {
      expect(() => loadConfig({ ...databricks, OTEL_EXPORTER_OTLP_TRACES_HEADERS: headers,
        OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: "https://1234.zerobus.example/v1/traces" })).toThrow(/x-databricks-zerobus-table-name/);
    }
    expect(() => loadConfig({ ...base, DAHLIA_OTEL_AUTH: "clickhouse" })).toThrow();
  });
});
