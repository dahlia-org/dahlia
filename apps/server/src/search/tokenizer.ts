export const SEARCH_QUERY_MAX_LENGTH = 500;
export const SEARCH_QUERY_MAX_TOKENS = 16;
export const SEARCH_ANALYZER_CONFIG_HASH = "e4e5d5c88f88895432fe3ec7e98b00ee2f05ca9ff6d78b47dda780ba6f5f308c";

export interface SearchTokenizer {
  tokenize(text: string): string[];
}

export interface SearchQuery {
  text: string;
  tokens: string[];
  sourceText: string;
}

export function createIntlSearchTokenizer(): SearchTokenizer {
  const segmenter = new Intl.Segmenter("ja", { granularity: "word" });
  return {
    tokenize(text) {
      return [...segmenter.segment(text.normalize("NFKC").toLowerCase())]
        .filter((segment) => segment.isWordLike)
        .map((segment) => segment.segment);
    },
  };
}

export function createSearchText(tokenizer: SearchTokenizer, values: Array<string | null | undefined>): string {
  return tokenizer.tokenize(values.filter(Boolean).join("\n")).join(" ");
}

export function parseSearchQuery(tokenizer: SearchTokenizer, input: string | undefined): SearchQuery | undefined {
  const query = input?.trim();
  if (!query) return undefined;
  if (query.length > SEARCH_QUERY_MAX_LENGTH) throw new SearchQueryError();
  const tokens = tokenizer.tokenize(query).filter(Boolean).slice(0, SEARCH_QUERY_MAX_TOKENS);
  return { text: tokens.join(" "), tokens, sourceText: query };
}

export class SearchQueryError extends Error {
  constructor() {
    super("invalid_search_query");
  }
}
