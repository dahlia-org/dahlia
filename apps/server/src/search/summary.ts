export function summarySearchableText(document: string | null): string {
  return summaryDisplayText(document);
}

export function summaryDisplayText(document: string | null): string {
  if (!document) return "";
  let value: unknown;
  try {
    value = JSON.parse(document);
  } catch {
    return "";
  }
  if (!isObject(value) || !Array.isArray(value.sections)) return "";
  const output = [stringValue(value.description)];
  for (const section of value.sections) {
    if (!isObject(section) || !Array.isArray(section.blocks)) continue;
    output.push(stringValue(section.heading));
    for (const block of section.blocks) output.push(...blockText(block));
  }
  return output.filter(Boolean).join("\n");
}

function blockText(value: unknown): string[] {
  if (!isObject(value)) return [];
  switch (value.type) {
    case "paragraph":
    case "quote":
    case "code":
    case "image":
    case "heading":
      return [summaryText(value.content)];
    case "bulleted_list":
    case "numbered_list":
      return Array.isArray(value.items) ? value.items.map(summaryText) : [];
    case "checklist":
      return Array.isArray(value.items) ? value.items.map((item) => isObject(item) ? stringValue(item.text) : "") : [];
    case "table":
      return [
        ...(Array.isArray(value.headers) ? value.headers.map(summaryText) : []),
        ...(Array.isArray(value.rows) ? value.rows.flatMap((row) => Array.isArray(row) ? row.map(summaryText) : []) : []),
      ];
    default:
      return [];
  }
}

function summaryText(value: unknown): string {
  return isObject(value) ? stringValue(value.text) : "";
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
