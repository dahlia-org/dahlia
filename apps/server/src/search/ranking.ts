export const SEARCH_CANDIDATE_LIMIT = 100;
export const RRF_K = 60;

export interface RankedSearchDocument {
  documentId: string;
  score: number;
  ftsRank: number;
  vectorRank: number;
}

export function reciprocalRankFusion(
  ftsIds: readonly string[],
  vectorIds: readonly string[],
): RankedSearchDocument[] {
  const ranks = new Map<string, RankedSearchDocument>();
  const add = (ids: readonly string[], field: "ftsRank" | "vectorRank") => ids.forEach((documentId, index) => {
    const rank = index + 1;
    const current = ranks.get(documentId) ?? {
      documentId,
      score: 0,
      ftsRank: Number.POSITIVE_INFINITY,
      vectorRank: Number.POSITIVE_INFINITY,
    };
    current.score += 1 / (RRF_K + rank);
    current[field] = rank;
    ranks.set(documentId, current);
  });
  add(ftsIds, "ftsRank");
  add(vectorIds, "vectorRank");
  return [...ranks.values()].sort((left, right) =>
    right.score - left.score
    || left.ftsRank - right.ftsRank
    || left.vectorRank - right.vectorRank
    || left.documentId.localeCompare(right.documentId)
  );
}
