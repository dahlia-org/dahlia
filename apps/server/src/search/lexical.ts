import { createIntlSearchTokenizer, SEARCH_QUERY_MAX_TOKENS, type SearchTokenizer } from "./tokenizer";

// Lakebase's built-in Japanese configuration; Dahlia installs lakebase_tokenizer into public like its other extensions.
export const LAKEBASE_JAPANESE_CONFIG = "public.tokenizer_japanese";

/**
 * The analyzer of Memory and chat chunks. tokenizer set: the application tokenizes and PostgreSQL indexes the tokens with
 * the simple configuration (SQLite: FTS5). tokenizer unset: PostgreSQL tokenizes chunk_text with `config`.
 * One database uses one analyzer; rows written by another one are rebuilt by reconciliation.
 */
export interface SearchAnalyzer {
  id: string;
  config: string;
  tokenizer?: SearchTokenizer;
  matchAll: boolean;
}

export function applicationAnalyzer(tokenizer: SearchTokenizer = createIntlSearchTokenizer()): SearchAnalyzer {
  return { id: tokenizer.analyzer ?? "custom", config: "simple", tokenizer, matchAll: tokenizer.matchAll ?? false };
}

function lakebaseAnalyzer(version: string): SearchAnalyzer {
  // The version is part of the ID: ALTER EXTENSION UPDATE does not regenerate stored tsvectors.
  return { id: `lakebase_tokenizer@${version}/tokenizer_japanese`, config: LAKEBASE_JAPANESE_CONFIG, matchAll: false };
}
/** Prefers lakebase_tokenizer on Lakebase when it is installed in public (version checked once); otherwise the application analyzer. */
export function analyzerResolver(lakebase: boolean, extensionVersion: () => Promise<string | undefined>) {
  let version: Promise<string | undefined> | undefined;
  return async (application: SearchAnalyzer): Promise<SearchAnalyzer> => {
    if (!lakebase) return application;
    const installed = await (version ??= extensionVersion().catch((error: unknown) => { version = undefined; throw error; }));
    return installed ? lakebaseAnalyzer(installed) : application;
  };
}
export const LAKEBASE_TOKENIZER_VERSION_SQL = "SELECT e.extversion FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'lakebase_tokenizer' AND n.nspname = 'public'";

/** Input for to_tsvector(analyzer.config, ...) at index and query time. */
export function analyzerInput(analyzer: SearchAnalyzer, text: string): string {
  return analyzer.tokenizer ? analyzer.tokenizer.tokenize(text).join(" ") : text;
}
/** Query tokens for the application analyzer, bounded like meeting search. */
export function queryTokens(analyzer: SearchAnalyzer, query: string): string[] {
  return [...new Set(analyzer.tokenizer!.tokenize(query))].slice(0, SEARCH_QUERY_MAX_TOKENS);
}

/** A tsquery of exact lexemes: quoted so that no query syntax or normalization applies. */
export function lexemeQuery(lexemes: readonly string[], matchAll: boolean): string {
  return lexemes.map((lexeme) => `'${lexeme.replaceAll("\\", "\\\\").replaceAll("'", "''")}'`).join(matchAll ? " & " : " | ");
}
/** An FTS5 query of quoted tokens. */
export function fts5Query(tokens: readonly string[], matchAll: boolean): string {
  return tokens.map((token) => `"${token.replaceAll('"', '""')}"`).join(matchAll ? " AND " : " OR ");
}

const encoder = new TextEncoder();
export async function contentHash(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(text));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function encodeFloat32(values: readonly number[]): Uint8Array {
  const buffer = new Float32Array(values);
  return new Uint8Array(buffer.buffer);
}
export function decodeFloat32(value: unknown): number[] {
  if (!(value instanceof Uint8Array) && !(value instanceof ArrayBuffer)) return [];
  const bytes = value instanceof Uint8Array
    ? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
    : new Uint8Array(value);
  if (bytes.byteLength % 4 !== 0) return [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return Array.from({ length: bytes.byteLength / 4 }, (_, index) => view.getFloat32(index * 4, true));
}

export function cosineSimilarity(left: readonly number[], right: readonly number[]): number {
  if (left.length !== right.length || left.length === 0) return Number.NaN;
  let dot = 0;
  let leftNorm = 0;
  let rightNorm = 0;
  for (let index = 0; index < left.length; index++) {
    dot += left[index]! * right[index]!;
    leftNorm += left[index]! ** 2;
    rightNorm += right[index]! ** 2;
  }
  return leftNorm && rightNorm ? dot / Math.sqrt(leftNorm * rightNorm) : Number.NaN;
}
