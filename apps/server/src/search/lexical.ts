import { createIntlSearchTokenizer, SEARCH_QUERY_MAX_TOKENS, type SearchTokenizer } from "./tokenizer";

// Lakebase's built-in Japanese configuration; migration installs lakebase_tokenizer into public like the other extensions.
export const LAKEBASE_JAPANESE_CONFIG = "public.tokenizer_japanese";

/**
 * The analyzer of Memory and chat chunks. tokenizer set: the application tokenizes and PostgreSQL indexes the tokens with
 * the simple configuration (SQLite: FTS5). tokenizer unset (Lakebase): the database tokenizes chunk_text with `config`.
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
  // "/runs2000": long unbroken runs are split before parsing (see parserSafe).
  return { id: `lakebase_tokenizer@${version}/tokenizer_japanese/runs2000`, config: LAKEBASE_JAPANESE_CONFIG, matchAll: false };
}
/** lakebase_tokenizer on Lakebase, where migration installs it (version read once per process); otherwise the application analyzer. */
export function analyzerResolver(lakebase: boolean, extensionVersion: () => Promise<string | undefined>) {
  let version: Promise<string> | undefined;
  return async (application: SearchAnalyzer): Promise<SearchAnalyzer> => {
    if (!lakebase) return application;
    return lakebaseAnalyzer(await (version ??= extensionVersion().then((installed) => {
      if (!installed) throw new Error("search_japanese_tokenizer_unavailable");
      return installed;
    }).catch((error: unknown) => { version = undefined; throw error; })));
  };
}
export const LAKEBASE_TOKENIZER_VERSION_SQL = "SELECT extversion FROM pg_extension WHERE extname = 'lakebase_tokenizer'";
/** Rows only when the schema-qualified text search configuration $1 exists (PostgreSQL has no to_regconfig). */
export const TEXT_SEARCH_CONFIG_SQL = `SELECT 1 FROM pg_ts_config c JOIN pg_namespace n ON n.oid = c.cfgnamespace
  WHERE format('%s.%s', n.nspname, c.cfgname) = $1`;

/** Input for to_tsvector(analyzer.config, ...) at index and query time. */
export function analyzerInput(analyzer: SearchAnalyzer, text: string): string {
  return analyzer.tokenizer ? analyzer.tokenizer.tokenize(text).join(" ") : parserSafe(text);
}

// PostgreSQL skips parser tokens over 2,047 bytes (Lakebase: 2,046) before any dictionary sees them; stay below with a margin.
export const PARSER_TOKEN_MAX_BYTES = 2_000;
const encoder = new TextEncoder();
const byteLength = (text: string) => encoder.encode(text).byteLength;
const script = (char: string) => /\p{Script=Han}/u.test(char) ? "han" : /\p{Script=Hiragana}/u.test(char) ? "hiragana"
  : /\p{Script=Katakana}/u.test(char) ? "katakana" : "other";
/**
 * Splits runs without whitespace or punctuation that exceed the parser's token limit with spaces, so database-side
 * analyzers still see long Japanese text. Cuts prefer the last change of script in the second half of a window
 * (for example 予算の|説明), which keeps most words whole; a word can still be cut where a run has no such change.
 */
export function parserSafe(text: string, maxBytes = PARSER_TOKEN_MAX_BYTES): string {
  return text.replace(/[^\s\p{P}\p{S}]+/gu, (run) => {
    const pieces: string[] = [];
    let rest = run;
    while (byteLength(rest) > maxBytes) {
      const chars: string[] = [];
      let bytes = 0;
      for (const char of rest) {
        if (bytes + byteLength(char) > maxBytes) break;
        bytes += byteLength(char); chars.push(char);
      }
      let cut = chars.length;
      for (let index = chars.length - 1; index > chars.length / 2; index--) {
        if (script(chars[index - 1]!) !== script(chars[index]!)) { cut = index; break; }
      }
      const piece = chars.slice(0, cut).join("");
      pieces.push(piece);
      rest = rest.slice(piece.length);
    }
    pieces.push(rest);
    return pieces.join(" ");
  });
}
/**
 * Meeting search on Lakebase: the database tokenizes documents and queries with LAKEBASE_JAPANESE_CONFIG, so text passes
 * whole. Text without letters or digits has no terms, like the application tokenizers.
 */
export function createLakebaseSearchTokenizer(): SearchTokenizer {
  return {
    tokenize(text) {
      const value = parserSafe(text.trim());
      return /[\p{L}\p{N}]/u.test(value) ? [value] : [];
    },
  };
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
