import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";

const manifest = JSON.parse(await readFile(new URL("../resources/codex/source.json", import.meta.url), "utf8"));
const output = new URL("../resources/codex/models.json", import.meta.url);
const check = process.argv.includes("--check");
let models;
let saved;
if (check) {
  // Offline checks validate the filtered artifact; upstream integrity is verified during generation.
  saved = await readFile(output, "utf8");
  ({ models } = JSON.parse(saved));
} else {
  const response = await fetch(manifest.source, { signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error(`Codex catalog download failed: HTTP ${response.status}`);
  const source = Buffer.from(await response.arrayBuffer());
  if (createHash("sha256").update(source).digest("hex") !== manifest.sha256) {
    throw new Error("Codex models.json must match the unmodified pinned upstream catalog");
  }
  ({ models } = JSON.parse(source.toString("utf8")));
}
const approved = manifest.models.map((slug) => {
  const model = models.find((model) => model.slug === slug);
  if (!model) throw new Error(`Missing approved Codex model: ${slug}`);
  return model;
});
// Ship only approved picker metadata; never persist the upstream catalog.
const projection = JSON.stringify({ models: approved.map(({ slug, display_name, supported_in_api, visibility,
  default_reasoning_level, supported_reasoning_levels, input_modalities }) => ({ slug, display_name, supported_in_api, visibility,
  default_reasoning_level, supported_reasoning_levels, input_modalities })) }, null, 2) + "\n";
if (check) {
  if (saved !== projection) throw new Error("Run pnpm codex-models:generate");
} else await writeFile(output, projection);
console.log(`${check ? "Verified" : "Generated"} Codex ${manifest.version} chat model metadata`);
