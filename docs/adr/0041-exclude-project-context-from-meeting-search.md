# ADR-0041: Project の文脈をミーティング検索から除外する

## Status

Accepted; amends ADR-0005, ADR-0033, ADR-0035, ADR-0037, and ADR-0040; builds on ADR-0034.

## Context

実データから生成した検索精度ベンチマークでは、`projectPath` の推奨重みが他フィールドより大きくなった。
一方、Project の名前と説明は要約生成の文脈として渡され、生成後の meeting title、description、tags、summary に
反映され得る。Project 自体の内容をミーティング検索でも独立した証拠として使うと、同じ文脈を重複して評価し、
Project 単位の偏りが強くなる。

Project は専用の検索結果と明示的な `project:`、`project`、`project_id` 絞り込みで探せるため、
ミーティングの自由文検索に含める必要はない。

## Decision

- Advanced のミーティング検索と重み設定は `title`、`tags`、`calendar`、`description`、`summary` の5フィールドを対象とし、`projectPath` を除外する。
- Simple のミーティング検索も Project 名と path を対象外にする。Project 専用検索と明示的な Project 絞り込みは維持する。
- Neural のミーティング順位は meeting vector だけで決め、Project vector の類似度による順位補正を行わない。
- MCP `query_meetings` の通常の FTS 検索も同じ5フィールドに限定する。`simple: true` は既存の部分一致対象から Project 名だけを除外し、既存の時系列順を維持する。
- 検索精度ベンチマークのクエリ生成と重み探索から `projectPath` を除外する。旧フィールド構成で保存した正解データは再利用せず、新しい保存キーで再生成する。
- `projectPath` の FTS カラムと Project 文書は Project 専用検索のため維持する。既存の Project vector はミーティング検索から参照しないため、索引再構築は不要とする。

## Consequences

- Project の文脈は、要約生成後の meeting metadata や summary に現れた場合だけミーティング検索へ寄与する。
- Project 名または path だけを自由文として入力しても、その Project に属するミーティングは一括表示されない。Project 結果または明示的な絞り込みを使う。
- Project vector の取得と順位補正がなくなり、Neural 検索時の SQLite query と cosine 計算が減る。
- 保存済みの検索重みでは未知の `projectPath` キーを無視し、残りの重みを維持する。

## References

- [ADR-0005](0005-vault-scoped-meeting-access-mcp.md)
- [ADR-0033](0033-use-local-fts5-search-projection.md)
- [ADR-0034](0034-index-summary-body-in-local-search.md)
- [ADR-0035](0035-add-local-hybrid-search.md)
- [ADR-0037](0037-use-actual-summary-content-for-meeting-vectors.md)
- [ADR-0040](0040-user-configurable-meeting-search-field-weights.md)
