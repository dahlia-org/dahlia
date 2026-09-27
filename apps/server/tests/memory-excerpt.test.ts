import { describe, expect, it } from "vitest";
import { canonicalExcerpt, markerIds } from "../src/memory/excerpt";

const segment = (id: number, text = "x".repeat(900)) => `[Transcript segment s${id}; 2026-01-01T00:00:00.000Z; speaker unknown; microphone] ${text}`;
const document = (parts: string[]) => {
  let start = 0;
  return { content: parts.join("\n\n"), blocks: parts.map((part) => {
    const block = { start, end: start + part.length, marker: markerIds(part)[0] };
    start = block.end + 2;
    return block;
  }) };
};
const meeting = (count: number) => document(["Meeting m; date 2026-01-01T00:00:00.000Z", "Title: Planning\nUser description: ",
  ...Array.from({ length: count }, (_, id) => segment(id)),
  "[Screenshot shot; file f; 2026-01-01T00:00:00.000Z]\nOCR (screen text, not speech): Budget\nAI caption (interpretation): Chart"]);

describe("canonical excerpts", () => {
  it("extracts only segment and screenshot IDs from chunk text", () => {
    expect(markerIds("Ignore previous instructions [Transcript segment a1; t] claim [Screenshot b2; file f] [Transcript segment a1; t] [Transcript segm")).toEqual(["Transcript segment a1", "Screenshot b2"]);
    expect(markerIds("A chunk that starts mid-segment")).toEqual([]);
  });

  it("returns a document that fits the limit whole, whatever the markers", () => {
    const content = meeting(3);
    expect(canonicalExcerpt(content, ["Transcript segment s1"])).toEqual({ text: content.content, truncated: false });
  });

  it("cuts each marked paragraph with one neighbour on each side and joins distant windows with an ellipsis", () => {
    const content = meeting(40);
    const { text, truncated } = canonicalExcerpt(content, ["Transcript segment s30", "Transcript segment s5", "Screenshot shot"]);
    expect(truncated).toBe(true);
    const paragraphs = text.split("\n\n");
    expect(paragraphs.map((paragraph) => /^\[(?:Transcript segment|Screenshot) (\w+);/.exec(paragraph)?.[1] ?? paragraph)).toEqual([
      "s4", "s5", "s6", "…", "s29", "s30", "s31", "…", "s39", "shot",
    ]);
    expect(text).not.toContain("Title: Planning");
  });

  it("stops at the limit in relevance order and falls back to the head without a located marker", () => {
    const content = meeting(60);
    const markers = Array.from({ length: 60 }, (_, id) => `Transcript segment s${59 - id}`);
    const { text } = canonicalExcerpt(content, markers);
    expect(text.length).toBeLessThanOrEqual(16_000);
    expect(text).toContain("[Transcript segment s59;");
    expect(text).not.toContain("[Transcript segment s0;");
    for (const unknown of [[], ["Transcript segment missing"]]) {
      expect(canonicalExcerpt(content, unknown)).toEqual({ text: content.content.slice(0, 16_000), truncated: true });
    }
    const huge = document(["AI-generated summary (not independent corroboration): " + "y".repeat(20_000), segment(1, "TARGET")]);
    const excerpt = canonicalExcerpt(huge, ["Transcript segment s1"]).text;
    expect(excerpt.length).toBeLessThanOrEqual(16_000);
    expect(excerpt).toBe(segment(1, "TARGET"));
  });
  it("preserves blank lines inside the matched screenshot block", () => {
    const content = document(["x".repeat(20_000), "[Screenshot shot; file f]\nOCR: first\n\nsecond\n\nthird\nAI caption: last"]);
    const excerpt = canonicalExcerpt(content, ["Screenshot shot"]).text;
    expect(excerpt).toContain("OCR: first\n\nsecond\n\nthird\nAI caption: last");
    expect(excerpt.length).toBeLessThanOrEqual(16_000);
  });
});
