# Local MCP と Project 階層

対象: Desktop・local MCP。採択: 2026-07。詳細な操作は [Project workspaces](../../project-workspaces.md)。

## Workspace 境界

署名済み stdio helper `dahlia-mcp` は `--workspace <ws_TypeID>`（互換名 `--workspace-id`）指定時に参照範囲を固定する。未指定時はアプリに追加済みの全 Workspace を対象にし、選択中のアカウントとは連動しない。`list_workspaces` は名前・アカウント種別・保持状態を返す。query は任意の `workspace_id` で絞り込み、省略時は Workspace ごとの結果・cursor・取得失敗を返す。詳細 ID の実所属と cursor の Workspace、meeting、ordering identity を検証し、明示 scope を広げない。

既定は SQLite read-only、明示 `--write` が公開 write tool を有効にする。helper は migration や permission 変更をせず、初期化時の schema 検証でアプリ更新後の初回起動を必要とする。

発見は compact metadata と [summary 本文の検索](search.md)、詳細は保存済み summary、原文 transcript のページング、縮小 screenshot を返す。保存済み取得では音声、note、翻訳、未確定 transcript と transcript 全文検索は対象外。未確定文を MCP へ公開しない。summary schema v3 の description と meeting metadata の更新は [サマリー](summary.md) に従う。

chat の workspace / 履歴は Workspace UUID で隔離する。Workspace 切替は新しい floating session とし、別 Workspace に紐づく detached session はその Workspace が active になるまで送信不可。start / resume とも user MCP を無効にして Dahlia helper を使い、要約は全 MCP を無効にする。設定画面は登録 command の表示・copy だけで外部 client 設定を書き換えない。外部 client の同名登録を別 Workspace へ変えるには明示的な再登録が必要。

## Project の正本

`projects.id` を安定 identity、parent ID + name を階層の正本とする。path は読込・操作計画時に導出し、別の正準 path を保存しない。採択時の nameKey は Unicode 正規化・case fold による sibling uniqueness を app / migration / MCP の共通処理で強制する契約とした。

root + 1 subproject の2段階に限定し、parent は同一 Workspace の root、子は children を持てない。root だけが明示 projectType を持ち、子は継承する。revision、Workspace 所有の不変性、同一 Workspace meeting membership を DB と各 writer で検証する。直接 SQL は supported mutation interface ではない。

## Export directory

directory は派生 Summary 出力先。Project 作成では作らず、rename / reparent で旧 derived path に沿う tracked Summary だけを移し、必要な directory を遅延作成する。無関係な file や directory 全体は動かさない。filesystem event は tracked export path を保守できるが、Project の作成・同定・rename・reparent・削除をしない。

file と DB の変更は shared Workspace lock、完全な事前検証、単一 DB transaction、失敗時の file compensation を使う。[summary 訂正](summary.md#訂正と-export) も同じ境界を共有する。

## 経緯と制約

slash-delimited path identity、親 ID と path の二重正本、Finder との双方向階層同期は、rename の fan-out と offline の曖昧性を増やすため却下した。任意階層と子への type 複製も製品に必要な範囲を超える。

旧 path migration は UUID、description、日時、membership を保ち、深い階層を元 root の直下へ平坦化し、名前衝突を決定的 suffix で解消した。既存 Summary は動かさず legacy path を保持し、旧 directory-sync / context column と CONTEXT.md 依存を廃止した。

local MCP の Project delete / merge は復旧契約を決めるまで公開しない。Server の domain transaction による削除は [同期契約](../shared/sync.md) の別経路として扱う。


## 部分保持本文の読み取り

helper は SQLite の完全性と保持 revision を検査し、不足する本文の取得と Server 全体の検索をアプリ側 `MeetingContentProvider` に既存の同梱 helper 用 IPC で依頼する。helper へ token を渡さず、アプリ側も要求の Workspace / meeting を検査する。保持済み本文はオフラインでも読み、利用日時の更新は best-effort の通知にする。transcript cursor に保持 revision を含め、異なる版をページ間で混ぜない。本文状態を `text_content` に返す。

本文 IPC は provider のページごとの通信期限で失敗を判定し、全ページ取得に画像用の合計30秒期限を適用しない。helper は本文取得完了の応答まで待つ。要求の書き込みと broker 側の応答書き込みには既存の期限を保ち、応答サイズ上限も維持する。broker 停止時は処理中の取得をキャンセルし socket を閉じる。

検索結果は従来のローカル `meetings` または `screenshots` / `next_cursor` と `search_scope` に、Server の `items` / `next_cursor` / `complete` / `error` を加える。Server の続きは独立した `server_cursor` で渡す。filter を適用してから Server ページを返し、取得失敗は未完了として表す。本文・要約を書き出す処理と同様、未保持の本文を空として成功させない。

## 確定文字起こしの差分取得（2026-09-10）

Local / Server の `get_meeting_transcript` に `after` と `wait` を追加する。`after` はワークスペース・会議・時間範囲に結び付いた不透明な取得位置で、空の結果でも `next_after` を返す。既読 prefix と世代の検証で編集・削除・再生成・途中への遅延挿入を検出し、利用側へ `after` を外した再取得を要求する。対象は会議全体で、既存の `cursor` と本文フィールドは維持する。`after` と `cursor` は同時指定しない。

`wait=true` は確定文がない場合だけ最大25秒待つ。待機中に DB トランザクションやロックを保持せず、Server は各読み取りで認証・共有権限を再確認し、切断で待機を終了する。本文未保持や認証失敗を新着なしとして扱わない。未確定文の MCP 公開、専用ライブツール、ライブ HTTP / SSE、プレビューストアは持たない。アプリのライブ字幕・音声認識・確定文同期は既存経路を維持する。

Local MCP は全ワークスペースを既定とし、`--write` 単独も許可する。任意の `--workspace` / `--workspace-id` は読み書きの範囲を制限する。更新・削除先は対象ID、新規作成先は明示的な `workspace_id` または一意の親IDで解決する。ワークスペースをまたぐ参照と曖昧な作成先は拒否する。操作例は [MCP の差分取得とワークスペース](../../live-mcp.md) を参照。
