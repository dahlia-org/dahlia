import { describe, expect, it, vi } from "vitest";
import { summaryEditor } from "../src/client/summary-editor";

describe("summary editing", () => {
  it("edits text without flattening structured content or discarding unknown fields", () => {
    const original = {
      schemaVersion: 3, title: "Before", description: "Overview", tags: ["planning"],
      metadata: { generatedBy: "server" }, futureField: "preserve",
      sections: [{ id: "section", heading: "Decisions", blocks: [
        { id: "paragraph", type: "paragraph", content: { text: "Original text", transcript_ref: "00:03:00" } },
        { id: "list", type: "bulleted_list", items: [{ text: "Item", transcript_ref: "00:05:00" }] },
        { id: "checklist", type: "checklist", items: [{ text: "Done", checked: true }] },
        { id: "table", type: "table", headers: [{ text: "Column" }], rows: [[{ text: "Cell" }]] },
        { id: "image", type: "image", screenshot_id: "file", content: { text: "Caption" } },
        { id: "code", type: "code", language: "sql", content: { text: "select 1" } },
        { id: "future", type: "unknown", extra: { text: "Do not rewrite" } },
      ] }], actionItems: [{ title: "Follow up", assignee: "Team" }],
    };
    const raw = JSON.stringify(original);
    const editor = summaryEditor(raw, original.title);
    const values = Object.fromEntries(editor.fields.map((field) => [field.name, field.value!]));
    expect(JSON.parse(editor.document(values))).toEqual(original);
    for (const field of editor.fields) values[field.name] = `${field.value!} edited`;
    values.title = "  New title  ";
    const edited = JSON.parse(editor.document(values)) as typeof original;
    expect(edited.title).toBe("New title");
    expect(edited.sections[0]!.blocks[0]!.content).toEqual({ text: "Original text edited", transcript_ref: "00:03:00" });
    expect(edited.sections[0]!.blocks[2]!.items).toEqual([{ text: "Done edited", checked: true }]);
    expect(edited.sections[0]!.blocks[3]!.rows).toEqual([[{ text: "Cell edited" }]]);
    expect(edited.sections[0]!.blocks[4]!.screenshot_id).toBe("file");
    expect(edited.sections[0]!.blocks[5]!.language).toBe("sql");
    expect(edited.sections[0]!.blocks[6]).toEqual(original.sections[0]!.blocks[6]);
    expect(edited.actionItems).toEqual([{ title: "Follow up edited", assignee: "Team edited" }]);
    expect(edited.metadata).toBeUndefined();
    expect(edited.futureField).toBe(original.futureField);
    expect(edited.tags).toEqual(original.tags);
    expect(JSON.stringify(original)).toBe(raw);
  });

  it("preserves legacy non-JSON text in an editable paragraph", () => {
    const raw = "# Legacy summary\n\n- Keep this text\n- And this line";
    const editor = summaryEditor(raw, "Legacy");
    const values = Object.fromEntries(editor.fields.map((field) => [field.name, field.value!]));
    const paragraph = editor.fields.find((field) => field.value === raw)!;
    expect(paragraph.multiline).toBe(true);
    values[paragraph.name] = `${raw}\nEdited`;
    const saved = JSON.parse(editor.document(values)) as { schemaVersion: number; sections: { blocks: { content: { text: string } }[] }[] };
    expect(saved.schemaVersion).toBe(3);
    expect(saved.sections[0]!.blocks[0]!.content.text).toBe(`${raw}\nEdited`);
  });

  it("creates a new structured summary and uses localized field labels", () => {
    for (const [language, label] of [["en-US", "Summary title"], ["ja-JP", "要約のタイトル"]]) {
      vi.stubGlobal("navigator", { language });
      const editor = summaryEditor(null, "Meeting");
      expect(editor.fields[0]!.label).toBe(label);
      const values = Object.fromEntries(editor.fields.map((field) => [field.name, field.value!]));
      values[editor.fields.at(-1)!.name] = "First line\nSecond line";
      const document = JSON.parse(editor.document(values)) as { schemaVersion: number; sections: { id: string; blocks: { content: { text: string } }[] }[] };
      expect(document.schemaVersion).toBe(3);
      expect(document.sections[0]!.blocks[0]!.content.text).toBe("First line\nSecond line");
      expect(document.sections[0]!.id).toMatch(/^[0-9a-f-]{36}$/);
      vi.unstubAllGlobals();
    }
  });
});
