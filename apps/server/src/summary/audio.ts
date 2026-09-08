import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { Readable } from "node:stream";
import { z } from "zod";
import type { AppConfig } from "../config";
import { personalWorkspaceId } from "../auth/workspace";
import { DatabricksBackend, resolveDatabricksModel } from "../ai-gateway/databricks";
import { DatabricksTokenError, DatabricksTokenProvider } from "../databricks/token";
import { GatewayRequestError } from "../ai-gateway/errors";
import { RequestError } from "../storage/upload";
import type { IdentitySyncStore, MeetingSyncStore } from "../sync/types";
import type { MeetingSyncService } from "../sync/service";
import type { RecordingManifest, RecordingSource } from "../recordings/model";
import { SummaryError, summaryDocument, summaryResponseSchema, type SummaryMethod } from "./model";
import { summaryResponseMetadataSchema } from "./metadata";
import { isAudioSummaryModel } from "./audio-model";
import { boundedBytes, collectSummaryInput, fingerprint, summaryImageContent, summaryInstructions, summaryXMLText } from "./transcript";

interface AudioInput {
  number: number; source: RecordingSource; startedAt: Date; endedAt: Date;
  size: number; checksum: string; manifest: RecordingManifest;
}
const MAX_AUDIO_SECONDS = 9.5 * 60 * 60;
async function collectAudio(store: IdentitySyncStore, vaultId: string, meetingId: string) {
  const context = await collectSummaryInput(store, vaultId, meetingId, false);
  const audio: AudioInput[] = [];
  let after = 0; let seconds = 0; let size = JSON.stringify(context).length;
  while (true) {
    const page = await store.listRecordings(meetingId, after, 200);
    for (const record of page) {
      for (const source of ["mic", "system"] as const) {
        const track = record.audio[source];
        if (!track?.active || !track.uploadedAt) continue;
        if (!track.manifest || !track.checksum) throw new SummaryError("summary_audio_unavailable");
        seconds += track.manifest.frameCount / track.manifest.sampleRate;
        if (seconds > MAX_AUDIO_SECONDS) throw new SummaryError("summary_audio_too_long");
        const input = { number: record.number, source, startedAt: record.startedAt, endedAt: record.endedAt,
          size: track.size, checksum: track.checksum, manifest: track.manifest };
        size += JSON.stringify(input).length;
        if (size > 2_000_000) throw new SummaryError("summary_input_too_large");
        audio.push(input);
      }
    }
    if (page.length < 200) break;
    after = page.at(-1)!.number;
  }
  if (!audio.length) throw new SummaryError("summary_audio_empty");
  return { ...context, audio };
}

// Stream base64 across arbitrary storage chunk boundaries; verify the committed bytes before publishing.
export async function* audioBase64(response: Response, size: number, checksum: string, signal: AbortSignal): AsyncGenerator<string> {
  if (!response.body) throw new SummaryError("summary_audio_unavailable");
  const reader = response.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => undefined); };
  signal.addEventListener("abort", cancel, { once: true });
  const hash = createHash("sha256");
  let received = 0; let carry = Buffer.alloc(0);
  try {
    while (true) {
      signal.throwIfAborted();
      const { value, done } = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      received += value.byteLength;
      if (received > size) throw new SummaryError("summary_audio_changed");
      hash.update(value);
      const bytes = Buffer.concat([carry, value]);
      const end = bytes.length - bytes.length % 3;
      if (end) yield bytes.subarray(0, end).toString("base64");
      carry = Buffer.from(bytes.subarray(end));
    }
    if (received !== size || `SHA-256:${hash.digest("hex")}` !== checksum) throw new SummaryError("summary_audio_changed");
    if (carry.length) yield carry.toString("base64");
  } finally {
    signal.removeEventListener("abort", cancel);
    await reader.cancel().catch(() => undefined);
    reader.releaseLock();
  }
}

export function createAudioSummaryMethod(config: AppConfig, store: MeetingSyncStore, sync: MeetingSyncService,
  transport: typeof fetch = fetch): SummaryMethod | undefined {
  const provider = config.provider;
  if (provider?.backend !== "databricks" || !config.databricksWorkspace) return undefined;
  const tokens = new DatabricksTokenProvider(config.databricksWorkspace, transport);
  const backend = new DatabricksBackend(provider, config.databricksWorkspace, transport);
  return {
    id: "audio",
    captureSettings: (settings, detail) => ({ ...settings.summary.methodSettings.audio,
      detail: detail ?? settings.summary.detail }),
    async version(scoped, vaultId, meetingId) { return fingerprint(await collectAudio(scoped, vaultId, meetingId)); },
    async generate(job, signal) {
      let requestId: string | undefined;
      try {
        const identity = { userId: job.ownerUserId, workspaceId: personalWorkspaceId(job.ownerUserId), source: "accounts" as const };
        const input = await store.withIdentity(identity, (scoped) => collectAudio(scoped, job.vaultId, job.meetingId));
        if (await fingerprint(input) !== job.inputVersion) throw new SummaryError("summary_input_changed");
        const configuredModel = job.settings.model.startsWith(`${provider.modelSchema}.`)
          ? job.settings.model.slice(provider.modelSchema.length + 1) : job.settings.model;
        const catalog = await backend.listModels({ signal });
        if (!isAudioSummaryModel(configuredModel, catalog)) throw new SummaryError("summary_invalid_audio_model");
        const levels = catalog.models.find((model) => model.slug === configuredModel)!.supported_reasoning_levels;
        if (!levels.some(({ effort }) => effort === job.settings.reasoningEffort)) throw new SummaryError("summary_invalid_reasoning_effort");
        const model = resolveDatabricksModel(provider, configuredModel);
        const { content, imageIds, images } = await summaryImageContent(input, sync, identity, signal);
        const chatContent = content.map((item) => item.type === "input_text"
          ? { type: "text", text: item.text } : { type: "image_url", image_url: { url: item.image_url } });
        const parameters = { model, stream: false, reasoning_effort: job.settings.reasoningEffort,
          response_format: { type: "json_schema", json_schema: { name: "meeting_summary", strict: true, schema: z.toJSONSchema(summaryResponseSchema) } } };
        const instructions = summaryInstructions(job.outputLanguage, job.settings.detail)
          + "\nSummarize the supplied audio directly. Use recording start times and manifest ranges to align mic/system tracks and screenshots; do not treat parallel tracks as consecutive conversations. Do not invent missing speech. Tags must contain only lowercase ASCII letters, digits and underscores, with at least one letter.";
        let streamFailure: Error | undefined;
        let complete = false;
        const uploadAbort = new AbortController();
        const uploadSignal = AbortSignal.any([signal, uploadAbort.signal]);
        async function* requestBody() {
          try {
            yield JSON.stringify(parameters).slice(0, -1) + ',"messages":['
              + JSON.stringify({ role: "system", content: instructions }) + ',{"role":"user","content":['
              + chatContent.map((item) => JSON.stringify(item)).join(",");
            for (const audio of input.audio) {
              uploadSignal.throwIfAborted();
              const response = await sync.recordingContent(identity, job.meetingId, String(audio.number), audio.source,
                new Request("https://dahlia.invalid/", { signal: uploadSignal }));
              if (!response.ok) {
                await response.body?.cancel();
                throw new SummaryError("summary_audio_unavailable", response.status >= 500);
              }
              yield ',' + JSON.stringify({ type: "text", text: `<audio>
  <recording_number>${audio.number}</recording_number>
  <source>${audio.source}</source>
  <start>${audio.startedAt.toISOString()}</start>
  <end>${audio.endedAt.toISOString()}</end>
  <manifest>
    <sample_rate>${audio.manifest.sampleRate}</sample_rate>
    <frame_count>${audio.manifest.frameCount}</frame_count>
    <ranges>${audio.manifest.ranges.map((range) => `
      <range><start_frame>${range.startFrame}</start_frame><frame_count>${range.frameCount}</frame_count><session_offset_seconds>${range.sessionOffsetSeconds}</session_offset_seconds><locale_identifier>${summaryXMLText(range.localeIdentifier)}</locale_identifier></range>`).join("")}
    </ranges>
  </manifest>
</audio>` })
                + ',{"type":"audio_url","audio_url":{"url":"data:audio/mp4;base64,';
              yield* audioBase64(response, audio.size, audio.checksum, uploadSignal);
              yield '"}}';
            }
            complete = true;
            yield "]}]}";
          } catch (error) { streamFailure = error instanceof Error ? error : new SummaryError("summary_audio_unavailable"); throw streamFailure; }
        }
        const endpoint = new URL(provider.baseUrl);
        endpoint.pathname = `${endpoint.pathname.replace(/\/$/, "")}/chat/completions`;
        const body = Readable.from(requestBody());
        const token = await tokens.getToken();
        let response: Response;
        try {
          const init: RequestInit & { duplex: "half" } = {
            method: "POST", signal, duplex: "half", body: (Readable.toWeb(body) as ReadableStream<string>).pipeThrough(new TextEncoderStream()),
            headers: { "content-type": "application/json", accept: "application/json", authorization: `Bearer ${token}`,
              "Databricks-Ai-Gateway-Request-Tags": JSON.stringify({ user_id: job.ownerUserId }) },
          };
          response = await transport(endpoint, init);
        } catch (error) { throw streamFailure ?? error; }
        finally { uploadAbort.abort(); body.destroy(); }
        const upstreamId = response.headers.get("x-databricks-request-id") ?? response.headers.get("x-request-id") ?? response.headers.get("request-id");
        requestId = upstreamId && /^[a-zA-Z0-9._:-]{1,128}$/.test(upstreamId) ? upstreamId : undefined;
        if (!response.ok) {
          await response.body?.cancel();
          throw new SummaryError(response.status === 413 ? "summary_audio_request_too_large" : `summary_http_${response.status}`,
            response.status === 429 || response.status >= 500, requestId);
        }
        if (streamFailure || !complete) { await response.body?.cancel(); throw streamFailure ?? new SummaryError("summary_audio_unavailable", true); }
        const parsed = summaryResponseMetadataSchema.pick({ id: true, model: true }).extend({ created: z.number().nullish(),
          usage: z.object({ prompt_tokens: z.number().optional(), completion_tokens: z.number().optional(), total_tokens: z.number().optional(), reasoning_tokens: z.number().optional(),
            prompt_tokens_details: z.object({ cached_tokens: z.number().optional() }).nullish(),
            completion_tokens_details: z.object({ reasoning_tokens: z.number().optional() }).nullish() }).nullish(),
          choices: z.array(z.object({ finish_reason: z.literal("stop"), message: z.object({ content: z.union([z.string(), z.array(z.object({ type: z.string(), text: z.string().optional() }))]) }) })).length(1),
        }).parse(JSON.parse(new TextDecoder().decode(await boundedBytes(response, 2 * 1024 * 1024))));
        // Databricks Gemini reports thinking tokens separately from completion_tokens.
        const usage = parsed.usage;
        const outputTokens = usage?.completion_tokens === undefined ? undefined
          : usage.completion_tokens + (usage.completion_tokens_details ? 0 : usage.reasoning_tokens ?? 0);
        const outputDetails = usage?.completion_tokens_details
          ?? (usage?.reasoning_tokens === undefined ? undefined : { reasoning_tokens: usage.reasoning_tokens });
        const message = parsed.choices[0]!.message.content;
        const text = typeof message === "string" ? message : message.filter((part) => part.type === "text").map((part) => part.text ?? "").join("");
        return { ...summaryDocument(JSON.parse(text), imageIds), metadata: {
          generatedBy: "server", inputTypes: ["context", "audio", ...(images.length ? ["image" as const] : [])],
          detailLevel: job.settings.detail, outputLanguage: job.outputLanguage,
          request: { model, reasoning: { effort: job.settings.reasoningEffort } },
          response: summaryResponseMetadataSchema.parse({ id: parsed.id, model: parsed.model, created_at: parsed.created,
            ...(usage ? { usage: { input_tokens: usage.prompt_tokens, output_tokens: outputTokens,
              total_tokens: usage.total_tokens, input_tokens_details: usage.prompt_tokens_details,
              output_tokens_details: outputDetails } } : {}) }),
        } };
      } catch (error) {
        if (error instanceof SummaryError) throw error;
        if (error instanceof RequestError) throw new SummaryError("summary_audio_unavailable", error.status >= 500);
        if (error instanceof GatewayRequestError) throw new SummaryError("summary_model_unavailable", error.status >= 500);
        if (error instanceof DatabricksTokenError) throw new SummaryError("summary_authentication_failed", error.retryable);
        if (error instanceof z.ZodError || error instanceof SyntaxError) throw new SummaryError("summary_invalid_response", false, requestId);
        throw new SummaryError("summary_processing_failed", true);
      }
    },
  };
}
