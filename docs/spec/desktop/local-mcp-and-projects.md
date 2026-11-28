# Local MCP と Project 階層

対象: Desktop・local MCP。採択: 2026-07。詳細な操作は [Project workspaces](../../project-workspaces.md)。

## Workspace 境界

署名済み stdio helper `dahlia-mcp` は `--workspace <ws_TypeID>`（互換名 `--workspace-id`）指定時に参照範囲を固定する。既存の登録との互換のため `--account local` と `--account <Dahlia account の UUID>` を受け付け、Workspace 指定とは排他にする。`local` は Server の所属を持たない Workspace、UUID はその Dahlia account の所属を残した Workspace を対象にする。Databricks の接続 ID・不明・削除済みの UUID では失敗し、全件へ戻さない。未指定時はアプリに追加済みの全 Workspace を対象にする。`list_workspaces` は名前・アカウント種別・`account_id`（Desktop の Workspace は `local`）・保持状態を返す。query は任意の `workspace_id` で絞り込み、省略時は Workspace ごとの結果・cursor・取得失敗を返す。詳細 ID の実所属と cursor の Workspace、meeting、ordering identity を検証し、明示 scope を広げない。

既定は SQLite read-only、明示 `--write` が公開 write tool を有効にする。`--write` 単独も許可する。任意の `--workspace` / `--workspace-id` は読み書きの範囲を制限する。更新・削除先は対象 ID、新規作成先は明示的な `workspace_id` または一意の親 ID で解決する。ワークスペースをまたぐ参照と曖昧な作成先は拒否する。helper は migration や permission 変更をせず、初期化時の schema 検証でアプリ更新後の初回起動を必要とする。

発見は compact metadata と [summary 本文の検索](search.md)、詳細は保存済み summary、原文 transcript のページング、保存済み screenshot（長辺1568px以下）を返す。保存済み取得では音声、note、翻訳、未確定 transcript と transcript 全文検索は対象外。未確定文を MCP へ公開しない。Notes（Documents）は MCP の対象外とする。summary schema v3 の description と meeting metadata の更新は [サマリー](summary.md) に従う。

## 同梱 skill

`dahlia-mcp` は MCP Skills extension（`io.modelcontextprotocol/skills`、SEP-2640）を capabilities の `extensions` に宣言し、`skills/list`・`skills/get`・`resources/list`・`resources/read` で skill を配布する。正本は `DahliaRuntimeSupport` の `Skills/` で、skill directory 内の全ファイルを `skill://dahlia/<name>/<path>` として公開し、manifest に SHA-256 digest と byte 長を載せる。アプリ内チャットの Pi は同じファイルを `--skill` で preset として読む（Pi 1.5.2 の MCP client は Skills extension に対応しないため）。extension 非対応の client 向けに、初期化時の instructions にも `SKILL.md` の URI を列挙する。read-only では書き込みで完結する skill（`summary-editor`）を一覧・取得から除く。skill は公開 tool の使い方だけを書き、新しいデータ経路を持たない。

| Skill | 担当 |
| --- | --- |
| dahlia-guide | 要約の入力・スクリーンショット選別・プロンプトの仕組みと、アプリの使い方・設定の案内 |
| meeting-reviewer | 1件の会議を目的に照らして振り返り、タイムスタンプ付きで改善点を示す |
| meeting-search | 検索パラメーター（`ical_uid`・`attendee`・Project・期間）の使い分けと検索シナリオ |
| projects-optimizer | Project 構成、meeting assignment、description の改善と Project の分け方 |
| summary-editor | 指示による訂正と、文字起こし・スクリーンショットを確認した見直し。証拠の判断基準を含む |

Thread は任意の Project だけに関連付ける。Project から Workspace を解決しない。Workspace 切替では会話を維持する。
chat の Dahlia helper は `--account` を付けずに起動し、Project の有無にかかわらずすべての Workspace を参照する。
start / resume とも Dahlia helper を使い、要約は全 MCP を無効にする。外部 client の登録範囲は chat の選択と独立する。

## Project の正本

`projects.id` を安定 identity、parent ID + name を階層の正本とする。path は読込・操作計画時に導出し、別の正準 path を保存しない。sibling の一意性は Unicode 正規化・case fold による nameKey で判定し、app / migration / MCP の共通処理で強制する。

root + 1 subproject の2段階に限定し、parent は同一 Workspace の root、子は children を持てない。root だけが明示 projectType を持ち、子は継承する。revision、Workspace 所有の不変性、同一 Workspace meeting membership を DB と各 writer で検証する。直接 SQL は supported mutation interface ではない。

## Export directory

directory は派生 Summary 出力先。Project 作成では作らず、rename / reparent で旧 derived path に沿う tracked Summary だけを移し、必要な directory を遅延作成する。無関係な file や directory 全体は動かさない。filesystem event は tracked export path を保守できるが、Project の作成・同定・rename・reparent・削除をしない。

file と DB の変更は shared Workspace lock、完全な事前検証、単一 DB transaction、失敗時の file compensation を使う。[summary 訂正](summary.md#訂正と-export) も同じ境界を共有する。

## 制約

既存の旧 path からの移行は UUID、description、日時、membership を保ち、深い階層を元 root の直下へ平坦化し、名前衝突を決定的 suffix で解消する。既存 Summary は動かさず、legacy path を保持する。

local MCP は Project の削除・統合を公開しない（復旧契約が未定のため）。Server の domain transaction による削除は [同期契約](../shared/sync.md) の別経路として扱う。

## 部分保持本文の読み取り

helper は SQLite の完全性と保持 revision を検査し、不足する本文の取得と Server 全体の検索をアプリ側 `MeetingContentProvider` に既存の同梱 helper 用 IPC で依頼する。helper へ token を渡さず、アプリ側も要求の Workspace / meeting を検査する。保持済み本文はオフラインでも読み、利用日時の更新は best-effort の通知にする。transcript cursor に保持 revision を含め、異なる版をページ間で混ぜない。本文状態を `text_content` に返す。

本文 IPC は provider のページごとの通信期限で失敗を判定し、全ページ取得に画像用の合計30秒期限を適用しない。helper は本文取得完了の応答まで待つ。要求の書き込みと broker 側の応答書き込みには既存の期限を保ち、応答サイズ上限も維持する。broker 停止時は処理中の取得をキャンセルし socket を閉じる。

検索結果は従来のローカル `meetings` または `screenshots` / `next_cursor` と `search_scope` に、Server の `items` / `next_cursor` / `complete` / `error` を加える。Server の続きは独立した `server_cursor` で渡す。filter を適用してから Server ページを返し、取得失敗は未完了として表す。本文・要約を書き出す処理と同様、未保持の本文を空として成功させない。

## 確定文字起こしの差分取得

採択: 2026-09-10。Local / Server の `get_meeting_transcript` は `after` と `wait` を受け付ける。`after` はワークスペース・会議・時間範囲に結び付いた不透明な取得位置で、空の結果でも `next_after` を返す。既読 prefix と世代の検証で編集・削除・再生成・途中への遅延挿入を検出し、利用側へ `after` を外した再取得を要求する。対象は会議全体で、既存の `cursor` と本文フィールドは維持する。`after` と `cursor` は同時指定しない。

`wait=true` は確定文がない場合だけ最大25秒待つ。待機中に DB トランザクションやロックを保持せず、Server は各読み取りで認証・共有権限を再確認し、切断で待機を終了する。本文未保持や認証失敗を新着なしとして扱わない。未確定文の MCP 公開、専用ライブツール、ライブ HTTP / SSE、プレビューストアは持たない。アプリのライブ字幕・音声認識・確定文同期は既存経路を維持する。操作例は [MCP の差分取得とワークスペース](../../live-mcp.md) を参照。

## 未適合・未検証

- 未確定: 文書取得・書き込みツールは次段階に置く。安定したブロック ID を備えることが前提だが、ツールの仕様と時期は未確定。

## 却下した案

- slash 区切りの path を identity にする: rename の fan-out と offline の曖昧性を増やすため。
- 親 ID と path の二重正本: rename の fan-out と offline の曖昧性を増やすため。
- Finder との双方向の階層同期: rename の fan-out と offline の曖昧性を増やすため。
- 任意の階層と子への type 複製: 製品に必要な範囲を超えるため。
