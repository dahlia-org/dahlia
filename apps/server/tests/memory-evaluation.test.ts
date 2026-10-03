import { expect, it } from "vitest";
import { encodeId } from "@dahlia-ai/ui/model/typeid";
import { evaluateMemory } from "../scripts/evaluate-memory";

it("scores final distinct documents and surviving excerpts, with only aggregate output", async () => {
  const ids = [1, 2].map((n) => encodeId("sharedMemory", `01990ab0-0000-7000-8000-00000000000${n}`));
  const queries = [{ query: "PRIVATE QUERY", expected: [{ id: ids[1]!, excerpts: ["kept evidence", "omitted evidence"], screenshotIds: ["image-kept", "image-other-document"] }] },
    { query: "FAIL QUERY", expected: [{ id: ids[0]!, excerpts: ["not returned"], screenshotIds: ["image-missing"] }] }];
  const result = await evaluateMemory(queries, async (query) => {
    if (query === "FAIL QUERY") throw new Error("PRIVATE FAILURE");
    return { results: [{ scope: "personal", result: { sources: ids.map((id) => ({
      id, kind: "shared", revision: "1", scope: "personal", meeting_id: null, workspace_id: null,
      canonicalExcerpt: id === ids[1]! ? "kept evidence" : "other", truncated: true,
      images: [{ screenshotId: id === ids[1]! ? "image-kept" : "image-other-document", fileId: "file", checksum: "hash", href: "/authorized" }],
    })), coverage: "ready", reflectionStatus: "partial", claims: [{ text: "PRIVATE CLAIM", citations: [{ factId: "fact", sourceIndexes: [1] }] }],
    reflectionUsage: { inputTokens: 30, outputTokens: 10 } } }] };
  });
  expect(result).toMatchObject({ questions: 2, errors: 1, hitAt5: 0.5, mrr: 0.25, excerptEvidenceRecall: 1 / 3,
    imageReferenceRecall: 1 / 3, claims: 1, reflectionStatuses: { partial: 1 }, reflectionUsage: { samples: 1, inputTokens: 30, outputTokens: 10 } });
  expect(JSON.stringify(result)).not.toMatch(/PRIVATE|smem_|image-kept|image-other|kept evidence|FAIL QUERY/);
});
