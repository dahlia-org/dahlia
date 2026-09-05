# サマリーの構造と更新

対象: Desktop・local MCP。採択: 2026-07-09〜08-02。

## 正準表現

Obsidian 記法を正本にせず、`SummaryDocument` AST から UI と各 export を生成する。LLM DTO は schema 互換性、AST は永続 identity / 検証、renderer は出力先固有記法を担当する。

section / block ID はアプリが採番する。transcript reference は複数の時刻・label を持つ block metadata、画像は読み順と caption を持つ content とする。旧文書の欠落 block ID は決定的に導出し、read → update の往復で変えない。未知 block type は paragraph へ fallback する。

strict LLM schema は単一 object の type discriminator と required fields を使い、DTO から変換時に画像所属を検証して旧記法を回収する。永続 `summaries.document` JSON が欠落・破損すれば legacy Markdown を読む。既存の `summaries.summary` と可読 Obsidian body を保持し、破壊的な既存行変換をしない。

AST / renderer / file locator は `DahliaRuntimeSupport` で app と helper が共有し、MCP のミラー型を持たない。schema v3 は最大240文字の一行 description を持つ。生成成功時は非空 title（最大120文字）と description を meeting へ反映し、空の legacy 値で有用な既存値を消さず、既存 meeting の一括 backfill はしない。

## 訂正と export

`--write` の `update_meeting_summary` は既存の1 meeting の document 全体を置き換える。人名等の訂正が複数 block にまたがっても1回で整合させるため、block patch や単純文字列置換は採用しない。

- 入力と `get_meeting.summary_document` は同じ schema 定数を共有し、未知 key、ID 省略、重複 ID、schema version、screenshot 所属、サイズを検証する。
- 保存済み document 文字列の SHA-256 を `summary_document_version` とし、更新時に expected version を要求する。別 writer の採番漏れを避け、再生成との衝突も検出する。Server transaction revision とは別の local MCP CAS 契約。
- Vault lock / prevalidation の後、既存 `summary_exports` の Vault path だけを更新する。未 export のファイルは作らず、title が変わっても rename しない。
- file を先に書き、DB transaction 失敗時は元内容へ補償する。補償失敗は `workspaceRollbackFailed` として表面化する。
- Google Docs を自動更新せず、`stale_exports: google_docs` を返す。app 不在でも Vault Markdown は helper が更新し、app は跨 process 通知で summary を再読込する。GRDB observation だけに依存しない。

## 理由と制約

Markdown 再パース、LLM DTO の直接保存、inline transcript metadata は出力先と内部モデルを結合するため却下した。中間層は増えるが同じ構造と renderer を共有できる。Obsidian の参照位置は旧 inline link と完全一致しない。

新規 summary 作成、MCP による filename 変更、Google Docs の自動追随はこの訂正契約に含めない。Slack / Google Docs renderer は初期の将来候補であり、実装済みとは扱わない。具体的な型は [SummaryDocument](../../../apps/desktop/Sources/DahliaRuntimeSupport/SummaryDocument.swift)、出力は [共有 renderer](../../../apps/desktop/Sources/DahliaRuntimeSupport/ObsidianMarkdownSummaryRenderer.swift) を参照し、型定義を文書へ複製しない。
