import { uuidV7 } from "../id";
import type { DialogField } from "./ActionDialog";
import { uiText } from "./api";

type Path = (string | number)[];
type ObjectValue = Record<string, unknown>;
const object = (value: unknown): ObjectValue => value && typeof value === "object" ? value as ObjectValue : {};
const array = (value: unknown): unknown[] => Array.isArray(value) ? value : [];

// Edit text in place: a plain-text conversion would discard lists, tables, references and attachments.
export function summaryEditor(raw: string | null | undefined, title: string) {
  const source: ObjectValue = raw ? object(JSON.parse(raw)) : {
    schemaVersion: 3, title, description: "", tags: [], actionItems: [],
    sections: [{ id: uuidV7(), heading: "", blocks: [{ id: uuidV7(), type: "paragraph", content: { text: "" } }] }],
  };
  const fields: DialogField[] = [{ name: "title", label: uiText("Summary title", "要約のタイトル"), value: title, required: true }];
  const paths = new Map<string, Path>([["title", ["title"]]]);
  function addTextField(path: Path, label: string, multiline = false) {
    const value = path.reduce<unknown>((value, key) => object(value)[key], source);
    if (typeof value !== "string") return;
    const name = `text-${fields.length}`;
    fields.push({ name, label, value, multiline });
    paths.set(name, path);
  }
  addTextField(["description"], uiText("Overview", "概要"), true);
  array(source.sections).forEach((sectionValue, sectionIndex) => {
    const section = object(sectionValue);
    const sectionPath: Path = ["sections", sectionIndex];
    const label = uiText(`Section ${sectionIndex + 1}`, `セクション ${sectionIndex + 1}`);
    addTextField([...sectionPath, "heading"], `${label} · ${uiText("Heading", "見出し")}`);
    array(section.blocks).forEach((blockValue, blockIndex) => {
      const block = object(blockValue);
      const path = [...sectionPath, "blocks", blockIndex];
      const prefix = `${label} · ${blockIndex + 1}`;
      addTextField([...path, "content", "text"], `${prefix} · ${uiText("Text", "本文")}`, true);
      array(block.items).forEach((_, index) => {
        addTextField([...path, "items", index, "text"], `${prefix} · ${uiText(`Item ${index + 1}`, `項目 ${index + 1}`)}`, true);
      });
      array(block.headers).forEach((_, index) => {
        addTextField([...path, "headers", index, "text"], `${prefix} · ${uiText(`Column ${index + 1}`, `列 ${index + 1}`)}`);
      });
      array(block.rows).forEach((row, rowIndex) => {
        array(row).forEach((_, columnIndex) => {
          const cellLabel = uiText(`Row ${rowIndex + 1}, column ${columnIndex + 1}`, `${rowIndex + 1}行 ${columnIndex + 1}列`);
          addTextField([...path, "rows", rowIndex, columnIndex, "text"], `${prefix} · ${cellLabel}`, true);
        });
      });
    });
  });
  array(source.actionItems).forEach((_, index) => {
    addTextField(["actionItems", index, "title"], uiText(`Action item ${index + 1}`, `アクションアイテム ${index + 1}`), true);
    addTextField(["actionItems", index, "assignee"], uiText(`Assignee ${index + 1}`, `担当者 ${index + 1}`));
  });
  return {
    fields,
    document(values: Record<string, string>) {
      const edited = structuredClone(source);
      for (const [name, path] of paths) {
        const parent = path.slice(0, -1).reduce<unknown>((value, key) => object(value)[key], edited);
        object(parent)[path.at(-1)!] = name === "title" ? values[name]!.trim() : values[name];
      }
      // A manually changed version must not claim to be the model's original output.
      if (JSON.stringify(edited) !== JSON.stringify(source)) delete edited.metadata;
      return JSON.stringify(edited);
    },
  };
}
