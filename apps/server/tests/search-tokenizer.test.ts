import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { createNodeSearchTokenizer } from "../src/search/node-tokenizer";
import {
  createIntlSearchTokenizer,
  parseSearchQuery,
  SEARCH_ANALYZER_CONFIG_HASH,
  SearchQueryError,
} from "../src/search/tokenizer";
import { summaryDisplayText, summarySearchableText } from "../src/search/summary";

describe("server search tokenization", () => {
  it("keeps the Node analyzer aligned with the desktop configuration and Japanese golden cases", () => {
    const analyzer = readFileSync(new URL("../../../Vendor/DahliaLinderaSources/analyzer.yml", import.meta.url));
    expect(createHash("sha256").update(analyzer).digest("hex")).toBe(SEARCH_ANALYZER_CONFIG_HASH);

    const tokenizer = createNodeSearchTokenizer();
    expect(tokenizer.tokenize("Ｌｉｎｄｅｒａで話した")).toEqual(["lindera", "話す"]);
    expect(tokenizer.tokenize("百二十三個のコンピューター")).toEqual(["123個", "コンピュータ"]);
    expect(tokenizer.tokenize("１２３個")).toEqual(["123個"]);
  });

  it("uses the Worker-safe segmenter for mixed Japanese and English", () => {
    expect(createIntlSearchTokenizer().tokenize("検索 Search １２３")).toEqual(["検索", "search", "123"]);
  });

  it("bounds queries without exposing search syntax", () => {
    const tokenizer = { tokenize: (text: string) => text.split(/\s+/) };
    expect(parseSearchQuery(tokenizer, "  alpha beta  ")).toEqual({
      text: "alpha beta",
      tokens: ["alpha", "beta"],
      sourceText: "alpha beta",
    });
    expect(parseSearchQuery(tokenizer, " ")).toBeUndefined();
    expect(parseSearchQuery(tokenizer, Array.from({ length: 20 }, (_, index) => `t${index}`).join(" "))?.tokens)
      .toHaveLength(16);
    expect(() => parseSearchQuery(tokenizer, "a".repeat(501))).toThrow(SearchQueryError);
  });
});

describe("summary search text", () => {
  it("extracts only displayed summary text", () => {
    const reference = "019d3f46-91e8-7ce0-ad52-bdd72825a61a";
    const text = summarySearchableText(JSON.stringify({
      schemaVersion: 3,
      title: "metadata title",
      description: "overview",
      tags: ["hidden tag"],
      actionItems: [{ title: "hidden action", assignee: "someone" }],
      sections: [{
        id: reference,
        heading: "Decisions",
        blocks: [
          { id: reference, type: "paragraph", content: { text: "Visible paragraph", transcript_ref: { time: "01:23" } } },
          { id: reference, type: "checklist", items: [{ text: "Visible task", checked: true }] },
          { id: reference, type: "table", headers: [{ text: "Column" }], rows: [[{ text: "Cell" }]] },
          { id: reference, type: "image", screenshot_id: reference, content: { text: "Visible image caption" } },
        ],
      }],
    }));
    expect(text).toContain("overview\nDecisions\nVisible paragraph\nVisible task\nColumn\nCell\nVisible image caption");
    expect(text).not.toContain(reference);
    expect(text).not.toContain("01:23");
    expect(text).not.toContain("hidden tag");
    expect(text).not.toContain("hidden action");
    expect(summaryDisplayText(JSON.stringify({
      description: "overview",
      sections: [{ heading: "Decisions", blocks: [{ type: "paragraph", content: { text: "Visible paragraph" } }] }],
    }))).toBe("overview\nDecisions\nVisible paragraph");
    expect(summarySearchableText("not-json")).toBe("");
  });
});
