import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const sourceDirectory = process.argv[2];
if (!sourceDirectory) throw new Error("Usage: node scripts/generate-databricks-models.mjs <codex-rs/models-manager directory>");

const source = JSON.parse(await readFile(join(sourceDirectory, "models.json"), "utf8"));
const prompt = await readFile(join(sourceDirectory, "prompt.md"), "utf8");
// Copy runtime metadata, not OpenAI-internal transports, hosted tools, or lifecycle controls.
const runtimeFields = [
  "description", "default_reasoning_level", "supported_reasoning_levels", "shell_type", "model_messages",
  "include_skills_usage_instructions", "include_plugin_usage_instructions", "include_apps_usage_instructions",
  "default_reasoning_summary", "supports_reasoning_summary_parameter", "support_verbosity", "default_verbosity",
  "apply_patch_tool_type", "truncation_policy", "supports_image_detail_original", "context_window", "max_context_window",
  "auto_compact_token_limit", "comp_hash", "effective_context_window_percent", "input_modalities", "model_specialty", "multi_agent_version",
];
const displayNames = {
  "gpt-6-astra": "GPT 6 Astra",
  "gpt-5.6-sol": "GPT 5.6 Sol",
  "gpt-5.6-terra": "GPT 5.6 Terra",
  "gpt-5.6-luna": "GPT 5.6 Luna",
};
const includedModels = new Set([
  "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "codex-auto-review",
]);
const models = source.models.filter((model) => includedModels.has(model.slug)).flatMap((model) => {
  const metadata = Object.fromEntries(runtimeFields.filter((field) => field in model).map((field) => [field, model[field]]));
  const entry = { slug: model.slug, display_name: displayNames[model.slug] ?? model.display_name, ...metadata };
  const publicID = model.slug.replaceAll(".", "-");
  // Codex merges by exact slug. Preserve dotted IDs for built-in suppression and OpenAI/Cloudflare clients.
  return publicID === model.slug ? [entry] : [entry, { ...entry, slug: publicID }];
});

// Descriptions paraphrase the official model cards linked in README.md (checked 2026-09-08).
const descriptions = {
  "glm-5-3": "Open-weight model for complex coding and long-running agent tasks.",
  "glm-5-3-flash": "Efficient multimodal model for coding, agents, and long-context tasks.",
  "kimi-k3": "Multimodal flagship for long-running coding, knowledge work, and reasoning.",
  "deepseek-v4-pro-0813": "Flagship model with enhanced agent capabilities, Responses API support, and Codex integration.",
  "gemini-3-8-flash": "Flash model for extended software engineering, autonomous agents, and complex enterprise tasks.",
  "gemini-3-7-flash": "Workhorse model for coding and agents, with improved debugging and issue resolution.",
};
const efforts = {
  low: "Fast responses with lighter reasoning",
  medium: "Balances speed and reasoning depth for everyday tasks",
  high: "Greater reasoning depth for complex problems",
  max: "Maximum reasoning depth for the hardest problems",
};
for (const [slug, displayName, levels, defaultLevel] of [
  ["glm-5-3", "GLM 5.3", ["low", "high", "max"], "max"],
  ["glm-5-3-flash", "GLM 5.3 Flash", ["low", "high", "max"], "max"],
  ["kimi-k3", "Kimi K3", ["low", "high", "max"], "max"],
  ["deepseek-v4-pro-0813", "DeepSeek V4 Pro", ["low", "high", "max"], "max"],
  ["gemini-3-8-flash", "Gemini 3.8 Flash", ["low", "medium", "high"], "medium"],
  ["gemini-3-7-flash", "Gemini 3.7 Flash", ["low", "medium", "high"], "medium"],
]) {
  const reference = models.find((model) => model.slug === (slug.endsWith("-flash") ? "gpt-5.6-luna" : "gpt-5.6-sol"));
  if (!reference) throw new Error(`Missing Codex reference for ${slug}`);
  let inputModalities = ["text", "image"];
  if (slug === "glm-5-3" || slug.startsWith("deepseek-")) {
    inputModalities = ["text"];
  } else if (slug.startsWith("gemini-")) {
    // Codex 0.153.4 accepts text, image, and audio; video is not a valid enum value.
    inputModalities = ["text", "image", "audio"];
  }
  models.push({
    ...reference,
    slug, display_name: displayName, description: descriptions[slug],
    model_messages: {
      ...reference.model_messages,
      instructions_template: reference.model_messages.instructions_template.replace("an agent based on GPT-5", "a coding agent"),
    },
    input_modalities: inputModalities,
    default_reasoning_level: defaultLevel,
    supported_reasoning_levels: levels.map((effort) => ({ effort, description: efforts[effort] })),
  });
}

await writeFile(new URL("../src/ai-gateway/databricks-models.json", import.meta.url), JSON.stringify({ models }, null, 2) + "\n");
await writeFile(new URL("../src/ai-gateway/codex-0.153.4-fallback.json", import.meta.url), JSON.stringify({ base_instructions: prompt }, null, 2) + "\n");
