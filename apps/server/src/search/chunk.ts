// Memory and chat search chunks: within this UTF-8 budget so one chunk stays a single embedding input.
export const SEARCH_CHUNK_MAX_BYTES = 8_000;

const encoder = new TextEncoder();
const byteLength = (text: string) => encoder.encode(text).byteLength;
// Preferred split points, strongest first: paragraph, line, sentence end.
const BREAKS = [/\n\s*\n/gu, /\n/gu, /[。．！？!?](?=\s|$)|[。．！？]|[.!?](?=\s)/gu];

/** Splits text into non-overlapping pieces of at most maxBytes; joining them returns the input. */
export function chunkText(text: string, maxBytes = SEARCH_CHUNK_MAX_BYTES): string[] {
  const chunks: string[] = [];
  let rest = text;
  while (byteLength(rest) > maxBytes) {
    // Longest code-point prefix within the budget.
    let end = 0, bytes = 0;
    for (const char of rest) {
      const size = byteLength(char);
      if (bytes + size > maxBytes) break;
      bytes += size; end += char.length;
    }
    const window = rest.slice(0, end);
    let cut = end;
    for (const pattern of BREAKS) {
      const last = [...window.matchAll(pattern)].at(-1);
      // Ignore breaks so early that they would leave a tiny chunk.
      if (last && last.index + last[0].length >= end / 4) { cut = last.index + last[0].length; break; }
    }
    chunks.push(rest.slice(0, cut));
    rest = rest.slice(cut);
  }
  if (rest) chunks.push(rest);
  return chunks;
}
