// Hindsight chunks only locate evidence: their IDs select paragraphs of the hash-verified canonical document.
const MARKER = /\[(Transcript segment|Screenshot) ([^;\]\s]+)/g;
const PARAGRAPH_MARKER = /^\[(Transcript segment|Screenshot) ([^;\]\s]+);/;
const GAP = "\n\n…\n\n";

export function markerIds(text: string) {
  return [...new Set(Array.from(text.matchAll(MARKER), ([, kind, id]) => `${kind} ${id}`))];
}

// Returns the whole document when it fits; otherwise the marked paragraphs with one neighbour on each side,
// chosen in relevance order and printed in document order. Without a located marker, the head is returned.
export function canonicalExcerpt(content: string, markers: readonly string[], limit = 16_000) {
  if (content.length <= limit) return { text: content, truncated: false };
  const paragraphs = content.split("\n\n");
  const positions = new Map<string, number>();
  paragraphs.forEach((paragraph, index) => {
    const match = PARAGRAPH_MARKER.exec(paragraph);
    if (match) positions.set(`${match[1]} ${match[2]}`, index);
  });
  const selected = new Set<number>();
  let length = 0;
  for (const marker of markers) {
    const position = positions.get(marker);
    if (position === undefined) continue;
    const window = [position - 1, position, position + 1].filter((index) => index >= 0 && index < paragraphs.length && !selected.has(index));
    const added = window.reduce((sum, index) => sum + paragraphs[index]!.length + GAP.length, 0);
    if (selected.size && length + added > limit) break;
    for (const index of window) selected.add(index);
    length += added;
  }
  if (!selected.size) return { text: content.slice(0, limit), truncated: true };
  const indices = [...selected].sort((a, b) => a - b);
  const text = indices.map((index, i) => (i === 0 ? "" : index === indices[i - 1]! + 1 ? "\n\n" : GAP) + paragraphs[index]).join("");
  return { text: text.slice(0, limit), truncated: true };
}
