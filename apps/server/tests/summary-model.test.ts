import { expect, it } from "vitest";
import { z } from "zod";
import { summaryDocument, summaryResponseSchema } from "../src/summary/model";

it("omits maxItems and accepts arrays beyond every former limit", () => {
  const text = { text: "Item", transcript_ref: null };
  const block = { type: "paragraph", level: 1, content: text, items: [], language: "", image_id: "" };
  const value = {
    title: "Meeting", description: "Summary",
    sections: [
      { heading: "Large", blocks: [{ ...block, items: Array.from({ length: 501 }, () => ({ ...text, checked: false })) },
        ...Array.from({ length: 500 }, () => block)] },
      ...Array.from({ length: 100 }, () => ({ heading: "Section", blocks: [] })),
    ],
    tags: Array.from({ length: 101 }, () => "tag"),
    action_items: Array.from({ length: 501 }, () => ({ title: "Action", assignee: "" })),
  };
  expect(JSON.stringify(z.toJSONSchema(summaryResponseSchema))).not.toContain("maxItems");
  expect(summaryResponseSchema.safeParse(value).success).toBe(true);
  for (const invalid of [
    { ...value, title: "x".repeat(121) }, { ...value, sections: [] }, { ...value, tags: ["Invalid Tag"] },
    { ...value, sections: [{ heading: "Section", blocks: [{ ...block, level: 7 }] }] },
    { ...value, description: undefined }, { ...value, action_items: ["Action"] },
  ]) expect(summaryResponseSchema.safeParse(invalid).success).toBe(false);
  expect(() => summaryDocument({ ...value, sections: [{ heading: "Image", blocks: [{ ...block, type: "image", image_id: "unknown" }] }] }, new Set()))
    .toThrow("summary_invalid_image_reference");
});
