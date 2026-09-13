import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { z } from "zod";
import type { AppConfig } from "../config";
import { createJobProvider } from "../ai-gateway/job-provider";
import { geminiChatResponse, geminiPart } from "./gemini";
import { DatabricksTokenError } from "../databricks/token";
import { GatewayRequestError } from "../ai-gateway/errors";
import { RequestError } from "../storage/upload";
import type { IdentitySyncStore, MeetingSyncStore } from "../sync/types";
import type { MeetingSyncService } from "../sync/service";
import { cloudTranscriptionSchema, combinedSummaryResponseSchema, generatedTranscript, transcriptionInstructions, type GeneratedTranscript } from "./transcription";
import type { RecordingManifest, RecordingSource, RecordingRecord } from "../recordings/model";
import { SummaryError, summaryDocument, summaryResponseSchema, type SummaryMethod, type SummaryJob, type SummaryInput, type SummaryGenerationResult } from "./model";
import { summaryResponseMetadataSchema } from "./metadata";
import { summaryStyleDetail } from "../account-settings-model";
import { resolveSummaryPreferences } from "./preferences";
import { isAudioSummaryModel, isSummaryModel } from "./audio-model";
import { assertSummaryAccess, boundedBytes, collectSummaryInput, fingerprint, summaryImageContent, summaryInstructions, summaryXMLText } from "./transcript";

interface AudioInput {
  recordingIndex: number; number: number; source: RecordingSource; startedAt: Date; endedAt: Date;
  size: number; checksum: string; manifest: RecordingManifest;
}
const MAX_AUDIO_SECONDS = 9.5 * 60 * 60;
async function collectAudio(store: IdentitySyncStore, workspaceId: string, meetingId: string, reference?: SummaryInput | null,
  requireCompleteMeeting = false) {
  const context = await collectSummaryInput(store, workspaceId, meetingId, false);
  if (requireCompleteMeeting && await store.hasPendingRecordings(meetingId)) throw new SummaryError("summary_audio_pair_incomplete");
  const records: RecordingRecord[] = [];
  let after = 0;
  while (true) {
    const page = await store.listRecordings(meetingId, after, 200);
    records.push(...page);
    if (records.length > 1000) throw new SummaryError("summary_input_too_large");
    if (page.length < 200) break;
    after = page.at(-1)!.number;
  }
  const selected = reference?.type === "recording" ? reference.recordings.map((pair) => {
    const record = records.find((record) => (["mic", "system"] as const).every((source) =>
      pair[source === "mic" ? "micFileId" : "systemFileId"] === null || record.audio[source]?.generation === pair[source === "mic" ? "micFileId" : "systemFileId"]));
    if (!record) throw new SummaryError("summary_audio_unavailable");
    for (const source of ["mic", "system"] as const) {
      const track = record.audio[source];
      if (track && (!pair[source === "mic" ? "micFileId" : "systemFileId"] || !track.active || !track.uploadedAt)) throw new SummaryError("summary_audio_pair_incomplete");
    }
    return record;
  }) : records;
  const audio: AudioInput[] = [];
  let seconds = 0; let size = JSON.stringify(context).length;
  for (const [recordingIndex, record] of selected.entries()) {
    for (const source of ["mic", "system"] as const) {
      const track = record.audio[source];
      if (!track?.active || !track.uploadedAt) continue;
      if (!track.manifest || !track.checksum) throw new SummaryError("summary_audio_unavailable");
      seconds += track.manifest.frameCount / track.manifest.sampleRate;
      if (seconds > MAX_AUDIO_SECONDS) throw new SummaryError("summary_audio_too_long");
      const input = { recordingIndex, number: record.number, source, startedAt: record.startedAt, endedAt: record.endedAt,
        size: track.size, checksum: track.checksum, manifest: track.manifest };
      size += JSON.stringify(input).length;
      if (size > 2_000_000) throw new SummaryError("summary_input_too_large");
      audio.push(input);
    }
  }
  if (!audio.length) throw new SummaryError("summary_audio_empty");
  return { ...context, audio };
}

function audioFingerprint(input: Awaited<ReturnType<typeof collectAudio>>) {
  // Array order already identifies the recording pair; keep accepted legacy job hashes unchanged.
  return fingerprint({ ...input, audio: input.audio.map((track) => ({ ...track, recordingIndex: undefined })) });
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
  const execution = createJobProvider(config, transport);
  if (!execution) return undefined;
  const { provider: audioProvider, backend, normalizeModel, resolveModel, headers: executionHeaders } = execution;
  const cloudflare = audioProvider.backend === "cloudflare";
  return {
    id: "audio",
    captureSettings: (settings, detail) => ({
      model: settings.processing.remote.summaryModel ?? "gemini-3-8-flash", reasoningEffort: settings.processing.remote.reasoningEffort ?? "medium",
      detail: detail ?? summaryStyleDetail(settings.summary.style),
    }),
    async resolvePreferences(preferences, input) {
      return resolveSummaryPreferences(preferences, input, await backend.listModels({ signal: AbortSignal.timeout(30_000) }), normalizeModel);
    },
    async version(scoped, workspaceId, meetingId, input, options) {
      return audioFingerprint(await collectAudio(scoped, workspaceId, meetingId, input, options?.requireCompleteMeeting));
    },
    async validateSettings(settings, input) {
      if (!input && !cloudflare) return;
      const catalog = await backend.listModels({ signal: AbortSignal.timeout(30_000) });
      const unqualified = normalizeModel;
      const summaryModel = unqualified(settings.model);
      if (!isSummaryModel(summaryModel, catalog, input?.type === "recording" && input.transcriptionModel ? "transcript" : "audio")) throw new SummaryError("summary_invalid_structured_model");
      const audioModel = input?.type === "recording" && input.transcriptionModel ? unqualified(input.transcriptionModel) : summaryModel;
      if (!isAudioSummaryModel(audioModel, catalog)) throw new SummaryError("summary_invalid_audio_model");
      if (input?.type === "recording" && input.transcriptionModel) {
        const model = catalog.models.find((model) => model.slug === audioModel)!;
        settings.transcriptionReasoningEffort = model.default_reasoning_level as typeof settings.transcriptionReasoningEffort;
        if (!settings.transcriptionReasoningEffort || !model.supported_reasoning_levels.some(({ effort }) => effort === settings.transcriptionReasoningEffort)) {
          throw new SummaryError("summary_invalid_reasoning_effort");
        }
      }
      if (!catalog.models.find((model) => model.slug === summaryModel)!.supported_reasoning_levels.some(({ effort }) => effort === settings.reasoningEffort)) {
        throw new SummaryError("summary_invalid_reasoning_effort");
      }
    },
    async transcribe(job, signal) {
      const result = await generateAudio(job, signal, true);
      if (!result.transcription) throw new SummaryError("summary_invalid_transcript");
      return result.transcription;
    },
    async generate(job, signal) {
      const result = await generateAudio(job, signal, false);
      if (!result.document) throw new SummaryError("summary_invalid_response");
      return result.document;
    },
  };
  async function generateAudio(job: SummaryJob, signal: AbortSignal, transcriptionOnly: boolean): Promise<{
    document?: SummaryGenerationResult; transcription?: GeneratedTranscript;
  }> {
      let requestId: string | undefined;
      try {
        const identity = { userId: job.ownerUserId, source: "accounts" as const };
        const input = await store.withIdentity(identity, (scoped) => collectAudio(scoped, job.workspaceId, job.meetingId, job.input));
        if (await audioFingerprint(input) !== job.inputVersion) throw new SummaryError("summary_input_changed");
        const selectedModel = transcriptionOnly && job.input?.type === "recording" ? job.input.transcriptionModel! : job.settings.model;
        const configuredModel = normalizeModel(selectedModel);
        const catalog = await backend.listModels({ signal });
        if (!isAudioSummaryModel(configuredModel, catalog)) throw new SummaryError("summary_invalid_audio_model");
        const levels = catalog.models.find((model) => model.slug === configuredModel)!.supported_reasoning_levels;
        const reasoningEffort = transcriptionOnly
          ? job.settings.transcriptionReasoningEffort ?? "medium"
          : job.settings.reasoningEffort;
        if (!levels.some(({ effort }) => effort === reasoningEffort)) throw new SummaryError("summary_invalid_reasoning_effort");
        const model = resolveModel(configuredModel);
        const { content, imageIds, images } = await summaryImageContent(input, sync, identity, signal);
        const chatContent = content.map((item) => item.type === "input_text"
          ? { type: "text", text: item.text } : { type: "image_url", image_url: { url: item.image_url } });
        const parameters = { model, stream: false, reasoning_effort: reasoningEffort,
          response_format: { type: "json_schema", json_schema: { name: "meeting_summary", strict: true, schema: z.toJSONSchema(transcriptionOnly ? cloudTranscriptionSchema : job.input ? combinedSummaryResponseSchema : summaryResponseSchema) } } };
        const instructions = (transcriptionOnly ? transcriptionInstructions : summaryInstructions(job.outputLanguage, job.settings.detail)
          + (job.input ? "\nReturn both summary and transcription in a single response. " + transcriptionInstructions : ""))
          + (transcriptionOnly ? "" : "\nSummarize the supplied audio directly. Use recording start times and manifest ranges to align mic/system tracks and screenshots; do not treat parallel tracks as consecutive conversations. Do not invent missing speech. Tags must contain only lowercase ASCII letters, digits and underscores, with at least one letter.");
        if (cloudflare && input.audio.reduce((bytes, audio) => bytes + 4 * Math.ceil(audio.size / 3), 0) > 20_000_000) {
          throw new SummaryError("summary_audio_request_too_large");
        }
        let streamFailure: Error | undefined;
        let complete = false;
        const uploadAbort = new AbortController();
        const uploadSignal = AbortSignal.any([signal, uploadAbort.signal]);
        async function* requestBody() {
          try {
            if (cloudflare) {
              const header = { model, input: { systemInstruction: { parts: [{ text: instructions }] },
                generationConfig: { responseMimeType: "application/json", responseJsonSchema: parameters.response_format.json_schema.schema,
                  thinkingConfig: { thinkingLevel: reasoningEffort.toUpperCase() } } } };
              yield JSON.stringify(header).slice(0, -2) + ',"contents":[{"role":"user","parts":['
                + content.map((part) => JSON.stringify(geminiPart(part))).join(",");
            } else {
              yield JSON.stringify(parameters).slice(0, -1) + ',"messages":['
                + JSON.stringify({ role: "system", content: instructions }) + ',{"role":"user","content":['
                + chatContent.map((item) => JSON.stringify(item)).join(",");
            }
            for (const audio of input.audio) {
              uploadSignal.throwIfAborted();
              const response = await sync.recordingContent(identity, job.meetingId, String(audio.number), audio.source,
                new Request("https://dahlia.invalid/", { signal: uploadSignal }));
              if (!response.ok) {
                await response.body?.cancel();
                throw new SummaryError("summary_audio_unavailable", response.status >= 500);
              }
              yield ',' + JSON.stringify({ ...(cloudflare ? {} : { type: "text" }), text: `<audio>
  <recording_index>${audio.recordingIndex}</recording_index>
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
                + (cloudflare ? ',{"inlineData":{"mimeType":"audio/mp4","data":"' : ',{"type":"audio_url","audio_url":{"url":"data:audio/mp4;base64,');
              yield* audioBase64(response, audio.size, audio.checksum, uploadSignal);
              yield '"}}';
            }
            complete = true;
            yield cloudflare ? "]}]}}" : "]}]}";
          } catch (error) { streamFailure = error instanceof Error ? error : new SummaryError("summary_audio_unavailable"); throw streamFailure; }
        }
        const endpoint = new URL(audioProvider.baseUrl);
        endpoint.pathname = cloudflare ? `${endpoint.pathname.replace(/\/v1\/?$/, "")}/run`
          : `${endpoint.pathname.replace(/\/$/, "")}/chat/completions`;
        const headers = await executionHeaders(job.ownerUserId);
        await store.withIdentity(identity, (scoped) => assertSummaryAccess(scoped, job.workspaceId));
        const iterator = requestBody();
        let sentBytes = 0;
        const encoder = new TextEncoder();
        const body = new ReadableStream<Uint8Array>({
          async pull(controller) {
            try {
              const next = await iterator.next();
              if (next.done) { controller.close(); return; }
              const bytes = encoder.encode(next.value);
              sentBytes += bytes.byteLength;
              if (cloudflare && sentBytes > 20_000_000) throw new SummaryError("summary_audio_request_too_large");
              controller.enqueue(bytes);
            } catch (error) {
              streamFailure = error instanceof Error ? error : new SummaryError("summary_audio_unavailable");
              uploadAbort.abort(); controller.error(streamFailure);
            }
          },
          async cancel() { uploadAbort.abort(); await iterator.return(); },
        });
        let response: Response;
        try {
          const init: RequestInit & { duplex: "half" } = {
            method: "POST", signal, duplex: "half", body,
            headers: { "content-type": "application/json", accept: "application/json", ...headers },
          };
          response = await transport(endpoint, init);
        } catch (error) { throw streamFailure ?? error; }
        finally { uploadAbort.abort(); await iterator.return(); }
        const upstreamId = response.headers.get("x-databricks-request-id") ?? response.headers.get("x-request-id") ?? response.headers.get("request-id");
        requestId = upstreamId && /^[a-zA-Z0-9._:-]{1,128}$/.test(upstreamId) ? upstreamId : undefined;
        if (!response.ok) {
          await response.body?.cancel();
          throw new SummaryError(response.status === 413 ? "summary_audio_request_too_large" : `summary_http_${response.status}`,
            response.status === 429 || response.status >= 500, requestId);
        }
        if (streamFailure || !complete) { await response.body?.cancel(); throw streamFailure ?? new SummaryError("summary_audio_unavailable", true); }
        const raw: unknown = JSON.parse(new TextDecoder().decode(await boundedBytes(response, 2 * 1024 * 1024)));
        const parsed = summaryResponseMetadataSchema.pick({ id: true, model: true }).extend({ created: z.number().nullish(),
          usage: z.object({ prompt_tokens: z.number().optional(), completion_tokens: z.number().optional(), total_tokens: z.number().optional(), reasoning_tokens: z.number().optional(),
            prompt_tokens_details: z.object({ cached_tokens: z.number().optional() }).nullish(),
            completion_tokens_details: z.object({ reasoning_tokens: z.number().optional() }).nullish() }).nullish(),
          choices: z.array(z.object({ finish_reason: z.literal("stop"), message: z.object({ content: z.union([z.string(), z.array(z.object({ type: z.string(), text: z.string().optional() }))]) }) })).length(1),
        }).parse(cloudflare ? geminiChatResponse(raw) : raw);
        // Databricks Gemini reports thinking tokens separately from completion_tokens.
        const usage = parsed.usage;
        const outputTokens = usage?.completion_tokens === undefined ? undefined
          : usage.completion_tokens + (usage.completion_tokens_details ? 0 : usage.reasoning_tokens ?? 0);
        const outputDetails = usage?.completion_tokens_details
          ?? (usage?.reasoning_tokens === undefined ? undefined : { reasoning_tokens: usage.reasoning_tokens });
        const message = parsed.choices[0]!.message.content;
        const text = typeof message === "string" ? message : message.filter((part) => part.type === "text").map((part) => part.text ?? "").join("");
        const responseMetadata = summaryResponseMetadataSchema.parse({ id: parsed.id, model: parsed.model, created_at: parsed.created,
          ...(usage ? { usage: { input_tokens: usage.prompt_tokens, output_tokens: outputTokens,
            total_tokens: usage.total_tokens, input_tokens_details: usage.prompt_tokens_details,
            output_tokens_details: outputDetails } } : {}) });
        const value: unknown = JSON.parse(text);
        const combined = !transcriptionOnly && job.input ? combinedSummaryResponseSchema.parse(value) : undefined;
        const transcript = transcriptionOnly || combined ? generatedTranscript(transcriptionOnly ? value : combined!.transcription, input.audio, {
          provider: "gemini", request: { model }, runs: [{ generatedBy: "server", inputTypes: ["audio"],
            audioInputs: input.audio.map(({ number, source, checksum }) => ({ recordingNumber: number, source, checksum })),
            startedAt: job.createdAt.toISOString(), completedAt: new Date().toISOString(), response: responseMetadata }],
        }) : undefined;
        if (transcriptionOnly) return { transcription: transcript };
        return { document: { ...summaryDocument(combined ? combined.summary : value, imageIds),
          ...(transcript ? { transcript } : {}), metadata: {
          generatedBy: "server", inputTypes: ["context", "audio", ...(images.length ? ["image" as const] : [])],
          detailLevel: job.settings.detail, outputLanguage: job.outputLanguage,
          request: { model, reasoning: { effort: reasoningEffort } }, response: responseMetadata,
        } } };
      } catch (error) {
        if (error instanceof SummaryError) throw error;
        if (error instanceof RequestError) throw new SummaryError("summary_audio_unavailable", error.status >= 500);
        if (error instanceof GatewayRequestError) throw new SummaryError("summary_model_unavailable", error.status >= 500);
        if (error instanceof DatabricksTokenError) throw new SummaryError("summary_authentication_failed", error.retryable);
        if (error instanceof z.ZodError || error instanceof SyntaxError) throw new SummaryError("summary_invalid_response", false, requestId);
        throw new SummaryError("summary_processing_failed", true);
      }

  }
}
