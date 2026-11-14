# サマリーの構造と更新

対象: Desktop・local MCP。Server 生成は [Server アカウントの要約生成](../server/summary-generation.md) を参照。採択: 2026-07-09〜08-02。

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
- 過去に書き出した Google Docs は自動更新せず、`stale_exports: google_docs` を返す。app 不在でも Vault Markdown は helper が更新し、app は跨 process 通知で summary を再読込する。GRDB observation だけに依存しない。

## 理由と制約

Markdown 再パース、LLM DTO の直接保存、inline transcript metadata は出力先と内部モデルを結合するため却下した。中間層は増えるが同じ構造と renderer を共有できる。Obsidian の参照位置は旧 inline link と完全一致しない。

新規 summary 作成、MCP による filename 変更、Google Docs の自動追随はこの訂正契約に含めない。app の Google Drive API による Google Docs export は 2026-11-11 に廃止した。Drive への書き出しは、共有メニューから Dahlia AI に依頼し、アカウントの Google Drive MCP が行う。定型プロンプトは My Drive 直下の `Meetings` 配下に `{meeting name} - YYYY/MM/DD HH:MM JST` の会議フォルダを作り、その中の `{meeting name} - YYYY/MM/DD HH:MM JST - Notes by Dahlia` という Google ドキュメントに、要約と文字起こし原文全文をこの順の2タブで書くよう指示する。日時は会議開始日時の JST 表記とし、原文は全ページ取得する。ツールが全文取得やタブ作成に対応しない場合は、未完了の内容を報告する。app は Drive の OAuth token・書き出し先 folder・export 履歴を新たに持たず、残っていた Drive token は起動時とアカウント削除時に Keychain から消す。過去の `google_docs` export 記録は読み取り専用で残し、「ブラウザで開く」とこの `stale_exports` だけに使う。具体的な型は [SummaryDocument](../../../apps/macos/Sources/DahliaRuntimeSupport/SummaryDocument.swift)、出力は [共有 renderer](../../../apps/macos/Sources/DahliaRuntimeSupport/ObsidianMarkdownSummaryRenderer.swift) を参照し、型定義を文書へ複製しない。

Server の `summaries` は全世代を保持する。Desktop の `summaries`（header）と `summary_bodies`（解放可能な本文）は最新のローカル保存を担い、Local Account の各版は `summary_versions` に本文と生成 metadata を保持する。導入時の既存本文を最初の版として引き継ぎ、以後は生成・Local MCP 訂正を含む本文変更を同じ transaction で保存する。同一本文の再保存では版を増やさない。Local Account の履歴は Server 同期の対象外とし、Workspace バックアップに含め、Meeting の削除で一緒に削除する。macOS の要約タブで過去版を閲覧し、バージョン表記の右に生成時のモデルと推論強度を表示する。クリックで開くポップオーバーで要求・応答モデルと推論強度・詳細度を確認でき、開閉で本文の位置は変わらない。言語と入力は表示しない。metadata のない旧版は生成情報不明と表示し、現在の設定から補完しない。Server Account の履歴は既存の履歴 API をページ取得し、過去版の閲覧では最新本文・export・検索対象を変更しない。macOS では表示中の過去版を正本へ昇格できる。本文と生成 metadata を保ったまま新しい最新版として保存し、元の版と昇格前の最新版は残す。Meeting 名・description・既存タグは変更しない。昇格は Local Account のみで有効にする。表示中の document をそのまま保存し、最新版の置換と履歴の追記を同じ transaction で行う。昇格時に Server API を呼ばず、同期 transaction も作らない。Server Account の昇格は同期方針の見直し後に扱う。昇格時は以前の export 記録を無効化し、書き出し済みファイル自体は自動変更しない。昇格操作は macOS アプリで提供し、Private Web・Electron と MCP には専用の昇格操作を設けない。latest の `version` はコンテンツ世代、`revision` は同期・本文取得検証用とし、ローカル MCP の本文 hash CAS とも区別する。
