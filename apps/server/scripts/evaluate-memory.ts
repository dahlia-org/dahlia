/** Operator-only evaluation of the production Server result. Never prints queries, IDs or content. */
import { readFile } from "node:fs/promises";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";
import { z } from "zod";
import { memoryResultSchema } from "../src/memory/dahlia";

export const questionsSchema = z.array(z.object({
  query: z.string().trim().min(1).max(4000),
  requiredClaims: z.array(z.string().min(1)).optional(), forbiddenClaims: z.array(z.string().min(1)).optional(),
  expected: z.array(z.object({ id: z.string().min(1), excerpts: z.array(z.string().min(1)),
    screenshotIds: z.array(z.string().min(1)).optional() }).refine((item) => item.excerpts.length > 0 || !!item.screenshotIds?.length)).min(1),
})).min(1);
export async function evaluateMemory(questions: z.infer<typeof questionsSchema>, send: (query: string) => Promise<unknown>) {
  let hits = 0, reciprocalRank = 0, evidence = 0, expected = 0, errors = 0, claims = 0, incomplete = 0;
  let missingCitations = 0, requiredClaims = 0, foundClaims = 0, forbiddenClaims = 0, duplicateMeetings = 0, refused = 0, noFacts = 0;
  let inputTokens = 0, outputTokens = 0, usageSamples = 0;
  let expectedImages = 0, imageEvidence = 0;
  const times: number[] = [];
  const statuses: Record<string, number> = {};
  for (const question of questionsSchema.parse(questions)) {
    expected += question.expected.reduce((n, source) => n + source.excerpts.length, 0);
    expectedImages += question.expected.reduce((n, source) => n + new Set(source.screenshotIds).size, 0);
    requiredClaims += question.requiredClaims?.length ?? 0;
    const start = performance.now();
    try {
      const response = memoryResultSchema.parse(await send(question.query));
      // Evaluate one explicit scope; do not merge personal and Workspace ranks.
      if (response.results?.length !== 1) throw new Error("scope");
      const result = response.results[0]!.result;
      if (result.code === "memory_policy_blocked" || result.skippedSources?.some((source) => source.code === "memory_policy_blocked")) refused++;
      if (result.skippedSources?.some((source) => source.code === "memory_no_facts")) noFacts++;
      if (result.unavailable) throw new Error("unavailable");
      const sources = (result.sources ?? []).slice(0, 5);
      const meetings = sources.flatMap((source) => source.meeting_id ? [source.meeting_id] : []);
      duplicateMeetings += meetings.length - new Set(meetings).size;
      const texts = (result.claims ?? []).map((claim) => claim.text);
      foundClaims += question.requiredClaims?.filter((expected) => texts.some((text) => text.includes(expected))).length ?? 0;
      forbiddenClaims += question.forbiddenClaims?.filter((forbidden) => texts.some((text) => text.includes(forbidden))).length ?? 0;
      for (const claim of result.claims ?? []) {
        if (!claim.citations.length || claim.citations.some((citation) => !citation.sourceIndexes.length
          || citation.sourceIndexes.some((index) => !sources[index]))) { missingCitations++; throw new Error("citation"); }
      }
      const rank = sources.findIndex((source) => question.expected.some((item) => item.id === source.id));
      if (rank >= 0) { hits++; reciprocalRank += 1 / (rank + 1); }
      for (const item of question.expected) {
        const source = sources.find((source) => source.id === item.id);
        evidence += item.excerpts.filter((excerpt) => source?.canonicalExcerpt.includes(excerpt)).length;
        imageEvidence += [...new Set(item.screenshotIds)].filter((id) => source?.images?.some((image) => image.screenshotId === id)).length;
      }
      claims += result.claims?.length ?? 0;
      if (result.coverage !== "ready") incomplete++;
      if (result.reflectionStatus) statuses[result.reflectionStatus] = (statuses[result.reflectionStatus] ?? 0) + 1;
      if (result.reflectionUsage) {
        inputTokens += result.reflectionUsage.inputTokens; outputTokens += result.reflectionUsage.outputTokens; usageSamples++;
      }
    } catch { errors++; }
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  return { questions: questions.length, errors, hitAt5: hits / questions.length, mrr: reciprocalRank / questions.length,
    excerptEvidenceRecall: expected ? evidence / expected : null, imageReferenceRecall: expectedImages ? imageEvidence / expectedImages : null,
    claims, incomplete, missingCitations, duplicateMeetings, refused, noFacts,
    claimExpectations: { required: requiredClaims, found: foundClaims, forbidden: forbiddenClaims }, reflectionStatuses: statuses,
    latencyMs: { p50: times[Math.ceil(times.length * 0.5) - 1], p95: times[Math.ceil(times.length * 0.95) - 1] },
    reflectionUsage: { samples: usageSamples, inputTokens, outputTokens } };
}

async function main() {
  try {
    const { values } = parseArgs({ options: { url: { type: "string" }, questions: { type: "string" },
      workspace: { type: "string" }, personal: { type: "boolean" }, reflect: { type: "boolean" } } });
    if (!values.url || !values.questions || Boolean(values.workspace) === Boolean(values.personal)) throw new Error("arguments");
    const url = new URL(values.url);
    if (url.username || url.password || (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))) throw new Error("origin");
    const questions = questionsSchema.parse((await readFile(values.questions, "utf8")).split(/\r?\n/).filter((line) => line.trim()).map((line) => JSON.parse(line) as unknown));
    const owner = values.personal ? "user" : `workspaces/${encodeURIComponent(values.workspace!)}`;
    const endpoint = new URL(`/api/v1/${owner}/memory/${values.reflect ? "reflect" : "recall"}`, url);
    const token = process.env.DAHLIA_MEMORY_EVAL_TOKEN;
    const result = await evaluateMemory(questions, async (query) => {
      const response = await fetch(endpoint, { method: "POST", redirect: "error", signal: AbortSignal.timeout(35_000),
        headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
        body: JSON.stringify({ query }),
      });
      if (!response.ok) { await response.body?.cancel(); throw new Error("request"); }
      return await response.json();
    });
    console.log(JSON.stringify(result));
  } catch { console.error("Memory evaluation failed: check arguments, input format and existing authentication."); process.exitCode = 1; }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) void main();
