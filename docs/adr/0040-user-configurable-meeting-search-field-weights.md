# ADR-0040: ミーティング検索の順位をユーザー設定のフィールド重みで決める

## Status

Accepted; amends ADR-0033 and ADR-0034.

## Context

ADR-0033 はミーティング検索の順位を、title、tag/path/calendar、description/summary という固定の証拠クラスで決めていた。実装はクラスを主キー、BM25 をタイブレークとして扱うため、token ごとに 6 フィールド分の単一カラム `MATCH` を発行し、最も弱い証拠のクラスと最小 BM25 で並べていた。

この階層は設計上の意図に基づくものではなく、どのフィールドを重視するかはユーザーと保管庫の内容によって変わる。title に社内の定型語が並ぶ保管庫では summary を優先したい一方、tag 運用が徹底された保管庫では tag を最優先したい。固定クラスではどちらにも合わせられず、BM25 のカラム重みを与えても順位はクラスに支配されるため効果がない。

## Decision

- ミーティング検索の順位は、フィールドごとの重みを BM25 のカラム重みとして与えた単一のスコアで決める。証拠クラスによる辞書式順位付けは廃止する。
- 重みは 0 から 10 の連続値とし、`title`、`tags`、`projectPath`、`calendar`、`description`、`summary` の 6 フィールドに設定する。重み 0 のフィールドは順位に寄与しないだけでなく、FTS5 のカラムフィルタで一致対象からも外す。全フィールドが 0 になる設定は既定へ戻す。
- 候補生成は ADR-0033 のまま、`fts5vocab` の文書頻度が最小の token を seed とし、残りの token を `EXISTS` で交差させる。seed と各 token の `MATCH` にも同じカラムフィルタを適用し、除外フィールドだけで一致した meeting を候補に含めない。
- 採点は候補に対して全 token の `AND` を一度だけ `MATCH` し、重み付き BM25 を取る。token ごと・フィールドごとの `MATCH` は発行しない。同点は meeting 日時の降順、次に meeting ID で解決する。
- 結果行が表示する一致フィールド（`searchMatchContext`）は、表示するページの meeting に限って、重みの高いフィールドから順にカラム限定の `MATCH` で判定する。候補全件には発行しない。
- 設定は `MeetingSearchRankingPolicy` として UserDefaults に JSON で保存し、検索の呼び出し側が引数として渡す。未設定と不正な JSON は既定のプリセットとして扱う。既定のプリセットは title を最優先し、tag、path/calendar、description/summary の順に下げる。
- 設定画面の検索カテゴリに、プリセット（標準、タイトル・タグ重視、内容重視、カスタム）とフィールドごとのスライダーを置く。プリセットの選択状態は保存せず、現在の重みから導出する。
- `simple` 検索と project 検索、screenshot 検索の順位は変更しない。screenshot の `caption` 重み（ADR-0038）も据え置く。
- MCP の `query_meetings` は既定の重みを使う。アプリの UserDefaults は `DahliaMeetingAccess` から参照しない。

## Consequences

- 順位が BM25 の連続値だけで決まるため、重みを変えると同じ query でも並び順が変わる。フィールドを跨いだ比較可能性は BM25 のカラム重みの意味論に従う。
- 重みはクエリ時にだけ使うため、変更しても索引の再構築は不要で、`indexGeneration` も進めない。
- token ごとに 6 フィールド分の `MATCH` を発行しなくなるため、候補が多い query の SQLite 実行回数が減る。
- 重み 0 のフィールドは検索対象から外れるが、`simple` 検索は ADR-0033 の比較用 literal substring 検索のままで、この除外を反映しない。
- MCP とアプリで同じ query の順位が食い違う場合がある。設定を共有するには `search_index_state` などの DB 側に置き直す必要があり、本 ADR では扱わない。

## References

- [ADR-0033](0033-use-local-fts5-search-projection.md)
- [ADR-0034](0034-index-summary-body-in-local-search.md)
- [ADR-0038](0038-index-screenshot-ocr-in-local-search.md)
