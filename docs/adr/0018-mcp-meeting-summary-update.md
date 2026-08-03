# ADR 0018: サマリーの訂正を MCP のドキュメント全体置換で行う

## Status

Accepted; amends 0005 and 0010, builds on 0001

## Date

2026-08-02

## Context

生成済みサマリーを訂正する手段が、アプリにも MCP にも存在しなかった。文字起こしが人名を取り違えたまま
サマリーに載った場合、ユーザーに残された選択肢はサマリー全体の再生成だけであり、再生成は
`summary_exports` を削除したうえで、正しかった部分まで書き換えてしまう。

[PRODUCT.md](../../PRODUCT.md) の T1 は「初期リリースで人が手作業する UI を提供してよい。ただしその機能は、
同じ操作を AI が実行できる粒度の Repository API と MCP tool を前提に設計する」と定めている。サマリーの訂正は
まさに整理作業であり、人だけが到達できる操作にしてはならない。アプリ内 Codex チャットは既に `--write` 付きで
`dahlia-mcp` を起動しているため、MCP に tool を追加すればそのままチャットから使える。

## Decision

`--write` のときだけ公開する `update_meeting_summary` を追加する。1 回の呼び出しで 1 つの Meeting の
サマリードキュメント全体を置き換える。

### ドキュメント全体を置き換える

ブロック単位の部分更新ではなく全体置換を選んだ。人名の取り違えのような訂正は複数のブロック、見出し、
タイトル、アクションアイテムの担当者にまたがることが多く、部分更新では 1 つの訂正が複数の呼び出しに分かれて
中途半端な状態を作りうる。

全体置換の弱点は、LLM が section id、block id、`screenshot_id`、`transcript_ref` を落とすと構造が壊れることである。
これは次の 2 つで塞ぐ。

- 入力スキーマは `get_meeting` が返す `summary_document` と**同一の定数**を共有する。全階層が
  `additionalProperties: false` で、block は `id` と `type` が required なので、id の省略と未知キーはスキーマ段階で
  弾かれる。
- ストア側で `schema_version`、section/block id の重複、`screenshot_id` の所属、サイズ上限を検証し、
  違反は黙って通さず明示的なエラーにする。

### `revision` 列ではなく内容ハッシュで compare-and-swap する

`summaries` に `revision` 列はない。列を追加する代わりに、保存済み `document` 文字列の SHA-256 を
`summary_document_version` として `get_meeting` が返し、更新時に `expected_document_version` として要求する。

マイグレーションが不要で、書き手が採番を忘れる余地がない。値は保存内容そのものから導かれるため、
アプリの再生成と MCP の更新のどちらが先に走っても衝突を検出できる。

### 要約 AST とレンダラーを共有ターゲットへ移す

`update_meeting_summary` は Vault へ書き出し済みの Markdown も更新する。MCP ヘルパーは別プロセスの別ターゲットで
あり `Sources/Dahlia` を参照できないため、`SummaryDocument` AST、`ObsidianMarkdownSummaryRenderer`、
`VaultSummaryFileLocator` を `DahliaRuntimeSupport` へ移し、アプリとヘルパーが同じ描画実装を使う。

これにより `DahliaMeetingAccess` が持っていた `StoredSummaryDocument` というミラー型が不要になり、読み出しと
書き込みで形が食い違う経路が構造的に消える。

`Action Items` 見出しだけはアプリの `.lproj` に属するため、レンダラーの引数にする。ja / en とも訳文が
`"Action Items"` で一致しているため既定値を共有ターゲットに置き、訳文が将来変わったら気付けるよう
`L10n.actionItems` との一致をテストで固定する。

### ファイルは新規作成せず、リネームもしない

`summary_exports` に `vault` 行がない Meeting に対してファイルを作らない。一度も書き出していないサマリーを
MCP が勝手に Vault へ出力するのは、ユーザーの書き出し設定を越える。

タイトルが変わってもファイル名は変更せず、既存パスへ上書きする。ファイル名は日付とタイトルから導かれるが、
リネームすると Obsidian 側のリンクが切れ、旧ファイルが残ると重複する。

ファイルは DB より先に書き、DB のトランザクションが失敗したら元の内容へ書き戻す。書き戻しに失敗した場合は
`workspaceRollbackFailed` として表面化させる。これは ADR 0010 が定めた Summary の
「Vault ロック → 完全な事前検証 → 単一トランザクション → 失敗時のファイル補償」と同じ手順である。

### Google Docs は追従させない

Google Docs の更新は認証付きの外部 API 呼び出しであり、チャットの一行の訂正で自動発火させない。
戻り値の `stale_exports` に `google_docs` を返し、古いままであることをエージェントとユーザーに伝える。

### block id 欠落時の fallback を決定的な導出に統一する

アプリの `SummaryBlock` は id を持たない旧ドキュメントを読むときランダムな `UUID.v7()` を採番していたが、
MCP のミラー型は coding path から決定的に導出していた。統合後は決定的な方を採用する。ランダム採番のままだと、
`get_meeting` が呼び出しごとに違う block id を返し、それがそのまま書き戻しへ往復して block の同一性が壊れる。

## Consequences

- アプリ内チャットと外部 CLI の両方から、要約の訂正が 1 回の呼び出しで完結する。
- Vault の Markdown は同期的に更新され、アプリが起動していなくても反映される。
- サマリー AST とレンダラーの実装が 1 つになり、MCP 側のミラー型が消える。
- `CaptionViewModel` はサマリーだけを読み直す経路を持つ。GRDB の `ValueObservation` は別プロセスの書き込みを
  検知しないため、Vault の変更通知が跨プロセス更新の合図になる。
- Google Docs の書き出しは古いままになる。追従が必要になった場合は別 ADR で決める。
- 要約が存在しない Meeting に対する新規作成と、ファイルのリネームは引き続きサポートしない。
- MCP 契約の変更であるため、次のリリース準備では minor を上げて patch を 0 に戻す
  ([AGENTS.md](../../AGENTS.md) の Release Versioning)。

## Alternatives considered

### ブロック単位の部分更新にする

ADR 0001 が想定した section id / block id による部分更新に沿うが、人名の訂正のように複数箇所へまたがる修正で
呼び出しが分かれ、途中で失敗すると一貫性のない状態が残る。却下した。

### 文字列の検索置換 tool にする

人名の訂正だけなら最も安全で冪等だが、文章の書き換えや加筆ができない。要約の更新という要求に対して狭すぎるため
却下した。

### `summaries` に `revision` 列を足す

ほかの書き込み tool と揃うが、マイグレーションが増え、すべての書き手が採番を守る必要が生じる。保存内容から
導かれるハッシュで同じ保証が得られるため却下した。

### アプリ側に書き出しを任せる

Vault の変更通知を受けたアプリが再書き出しする案は、レンダラーの移設が不要になる。しかしアプリが起動していない
ときに反映されず、追いつかせるための staleness 列と照合処理が必要になる。却下した。
