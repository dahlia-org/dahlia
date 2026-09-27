import type { MemoryDocument } from "./model";

// Hindsight chunks only locate evidence: their IDs select hash-verified canonical blocks.
const MARKER = /\[(Transcript segment|Screenshot) ([^;\]\s]+)/g;
const GAP = "\n\n…\n\n";

export function markerIds(text: string) {
  return [...new Set(Array.from(text.matchAll(MARKER), ([, kind, id]) => `${kind} ${id}`))];
}

// Positions come from canonical construction, never from parsing user-authored text.
// Reserve matching blocks before adding neighbours; a long neighbour must not displace the evidence.
export function canonicalExcerpt({ content, blocks = [] }: Pick<MemoryDocument, "content" | "blocks">, markers: readonly string[], limit = 16_000) {
  if (content.length <= limit) return { text: content, truncated: false };
  const positions = new Map<string, number>();
  blocks.forEach((block, index) => { if (block.marker) positions.set(block.marker, index); });
  const matches = new Set<number>();
  for (const marker of markers) {
    const position = positions.get(marker);
    if (position !== undefined) matches.add(position);
  }
  const selected = new Map<number, { start: number; end: number }>();
  let remaining = limit;
  const add = (index: number, allowPartial = false) => {
    const block = blocks[index];
    if (!block || selected.has(index)) return;
    const separator = selected.size ? GAP.length : 0;
    const available = remaining - separator;
    const blockLength = block.end - block.start;
    // Keep context labels intact: omit a neighbour that cannot fit in full.
    if (!allowPartial && blockLength > available) return;
    const length = Math.min(blockLength, available);
    if (length <= 0) return;
    selected.set(index, { start: block.start, end: block.start + length });
    remaining -= length + separator;
  };
  for (const index of matches) add(index, true);
  for (const index of matches) { add(index - 1); add(index + 1); }
  if (!selected.size) return { text: content.slice(0, limit), truncated: true };
  const ranges = [...selected.values()].sort((a, b) => a.start - b.start);
  const text = ranges.map((range, index) => {
    const excerpt = content.slice(range.start, range.end);
    const previous = ranges[index - 1];
    if (!previous) return excerpt;
    const separator = range.start === previous.end + 2 ? "\n\n" : GAP;
    return separator + excerpt;
  }).join("");
  return { text, truncated: true };
}
