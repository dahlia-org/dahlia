import type { z } from "zod";
import { generationPreferencesSchema, summaryStyleDetail } from "../workspace-generation-settings";
import type { GatewayModelList } from "../ai-gateway/backend";
import { isAudioSummaryModel, isSummaryModel } from "./audio-model";
import { SummaryError, type SummaryInput, type TranscriptSettings } from "./model";

type StoredGenerationPreferences = z.infer<typeof generationPreferencesSchema>;
export type GenerationPreferences = Omit<StoredGenerationPreferences, "transcription"> & {
  transcription?: StoredGenerationPreferences["transcription"];
};

// Deliberate product defaults, not catalog order. Unknown deployments require an explicit selection.
const preferredSummaryModels = ["system.ai.gemini-3-8-flash", "gemini-3-8-flash", "gpt-5.4", "gpt-4.1", "gemini-3-flash"];
const preferredTranscriptionModels = ["system.ai.gemini-3-8-flash", "system.ai.gemini-3-7-flash", "gemini-3-8-flash", "gemini-3-7-flash", "gemini-3-flash"];

export function resolveSummaryPreferences(
  preferences: GenerationPreferences, input: SummaryInput, catalog: GatewayModelList,
  normalizeModel: (model: string) => string,
): { settings: TranscriptSettings; input: SummaryInput } {
  const remote = preferences.processing.remote;
  const transcriptionOnly = input.type === "recording" && input.transcriptionOnly === true;
  const twoStage = input.type === "recording" && (transcriptionOnly || remote.workflow === "transcribeThenSummarize");
  const method = input.type === "transcript" || twoStage ? "transcript" : "audio";
  const choose = (explicit: string | undefined, preferred: string[], supported: (model: string) => boolean, error: string) => {
    const selected = explicit === undefined ? preferred.find(supported) : normalizeModel(explicit);
    if (!selected || !supported(selected)) throw new SummaryError(error);
    return selected;
  };
  const model = transcriptionOnly
    ? choose(remote.transcriptionModel, preferredTranscriptionModels,
      (id) => isAudioSummaryModel(id, catalog), "summary_invalid_audio_model")
    : choose(remote.summaryModel, preferredSummaryModels,
      (id) => id !== "codex-auto-review" && isSummaryModel(id, catalog, method), "summary_invalid_structured_model");
  const modelInfo = catalog.models.find(({ slug }) => slug === model)!;
  // Retranscription does not run the saved summary configuration. Its audio
  // model owns the reasoning level used by the transcription request.
  const reasoningEffort = transcriptionOnly
    ? modelInfo.default_reasoning_level
    : remote.reasoningEffort ?? modelInfo.default_reasoning_level;
  if (!modelInfo.supported_reasoning_levels.some(({ effort }) => effort === reasoningEffort)) {
    throw new SummaryError("summary_invalid_reasoning_effort");
  }
  const settings: TranscriptSettings = {
    model, reasoningEffort: reasoningEffort as TranscriptSettings["reasoningEffort"],
    detail: summaryStyleDetail(preferences.summary.style),
    ...(transcriptionOnly ? {} : { transcription: preferences.transcription }),
  };
  if (input.type === "transcript") return { settings, input };
  const resolvedInput: SummaryInput = {
    type: "recording", recordings: input.recordings,
    ...(transcriptionOnly ? { transcriptionOnly: true as const } : {}),
  };
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
