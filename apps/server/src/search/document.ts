import { SEARCH_FIELDS, type SearchField } from "./settings-model";
import { summarySearchableText, summaryTags } from "./summary";
import { createSearchText, type SearchTokenizer } from "./tokenizer";

export type SearchDocumentFields = Record<`${SearchField}Text`, string>;

function searchText(tokenizer: SearchTokenizer, values: Partial<Record<SearchField, string | null | undefined>>) {
  const fields = Object.fromEntries(SEARCH_FIELDS.map((field) =>
    [`${field}Text`, createSearchText(tokenizer, [values[field]])])) as SearchDocumentFields;
  return { searchFields: fields, searchText: SEARCH_FIELDS.map((field) => fields[`${field}Text`]).filter(Boolean).join(" ") };
}

export function meetingSearchText(tokenizer: SearchTokenizer, title: string, description: string, document: string | null) {
  return searchText(tokenizer, { title, description, tags: summaryTags(document).join("\n"), summary: summarySearchableText(document) });
}

export function screenshotSearchText(tokenizer: SearchTokenizer, ocr: string | null | undefined, caption: string | null | undefined) {
  return searchText(tokenizer, { ocr, caption });
}
