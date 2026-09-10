import type { z } from "zod";
import { generationPreferencesSchema, summaryStyleDetail } from "../account-settings-model";
import type { GatewayModelList } from "../ai-gateway/backend";
import { isAudioSummaryModel, isSummaryModel } from "./audio-model";
import { SummaryError, type SummaryInput, type TranscriptSettings } from "./model";

export type GenerationPreferences = z.infer<typeof generationPreferencesSchema>;

// Deliberate product defaults, not catalog order. Unknown deployments require an explicit selection.
const preferredSummaryModels = ["gemini-3-8-flash", "gpt-5.4", "gpt-4.1", "gemini-3-flash"];
const preferredTranscriptionModels = ["gemini-3-8-flash", "gemini-3-7-flash", "gemini-3-flash"];

export function resolveSummaryPreferences(
  preferences: GenerationPreferences, input: SummaryInput, catalog: GatewayModelList,
  normalizeModel: (model: string) => string,
): { settings: TranscriptSettings; input: SummaryInput } {
  if (preferences.processing.location !== "remote") throw new SummaryError("summary_remote_processing_required");
  const remote = preferences.processing.remote;
  const twoStage = input.type === "recording" && remote.workflow === "transcribeThenSummarize";
  const method = input.type === "transcript" || twoStage ? "transcript" : "audio";
  const choose = (explicit: string | undefined, preferred: string[], supported: (model: string) => boolean, error: string) => {
    const selected = explicit === undefined ? preferred.find(supported) : normalizeModel(explicit);
    if (!selected || !supported(selected)) throw new SummaryError(error);
    return selected;
  };
  const model = choose(remote.summaryModel, preferredSummaryModels,
    (id) => id !== "codex-auto-review" && isSummaryModel(id, catalog, method), "summary_invalid_structured_model");
  const modelInfo = catalog.models.find(({ slug }) => slug === model)!;
  const reasoningEffort = remote.reasoningEffort ?? modelInfo.default_reasoning_level;
  if (!modelInfo.supported_reasoning_levels.some(({ effort }) => effort === reasoningEffort)) {
    throw new SummaryError("summary_invalid_reasoning_effort");
  }
  const settings: TranscriptSettings = {
    model, reasoningEffort: reasoningEffort as TranscriptSettings["reasoningEffort"],
    detail: summaryStyleDetail(preferences.summary.style),
  };
  if (input.type === "transcript") return { settings, input };
  const resolvedInput: SummaryInput = { type: "recording", recordings: input.recordings };
  if (twoStage) {
    const transcriptionModel = choose(remote.transcriptionModel, preferredTranscriptionModels,
      (id) => isAudioSummaryModel(id, catalog), "summary_invalid_audio_model");
    const metadata = catalog.models.find(({ slug }) => slug === transcriptionModel)!;
    if (!metadata.supported_reasoning_levels.some(({ effort }) => effort === metadata.default_reasoning_level)) {
      throw new SummaryError("summary_invalid_reasoning_effort");
    }
    settings.transcriptionReasoningEffort = metadata.default_reasoning_level as TranscriptSettings["reasoningEffort"];
    resolvedInput.transcriptionModel = transcriptionModel;
  }
  return { settings, input: resolvedInput };
}
