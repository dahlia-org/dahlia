# Workspace archive backup / restore

対象: Desktop。採択: 2026-07-18。Workspace 単位の保存・復元: 2026-09-06 に採択。

## 世代と対象

複数の Workspace を選択して一つの gzip 圧縮 tar（`.tar.gz`）にまとめ、Application Support/Dahlia/Backups にユーザー削除まで保持する。自動で世代数を減らさない。
現行形式の manifest と各 DB snapshot に元の Workspace UUID・名前の一覧、世代 UUID、日時、schema / migration、app version/build、理由を埋め込む。
単一の DB snapshot から選択した全 Workspace を抽出し、途中で失敗した世代は公開しない。
現行 manifest を持つ tar.gz だけを読み込み・復元の対象とする。

対象は選択した Workspace の DB 内データと参照関係。Project 階層、会議、文字起こし・翻訳、session timeline、要約、files の metadata、会議との紐付け、スクリーンショットの OCR / caption を含む。原本は `files/{fileId}/original`、DB は `database.sqlite` として格納し、`manifest.json` に各 entry のサイズと SHA-256 を記録する。
対象 Workspace の原本は FileStore から取り込む。端末固有の画像ファイル参照は含めない。
共有タグ・カレンダー情報は対象会議から参照されるものだけを保存する。
明示した対象テーブルから新しい DB へコピーするため、他 Workspace の内容は含まれない。原文・要約・OCR / caption の専用本文テーブルもコピーし、親 metadata に対応する本文の欠損があれば世代の公開・復元を拒否する。本文の保持状態や同期 state はコピーしない。
音声本体・参照、Workspace Markdown / 添付、端末の出力先、UserDefaults、アカウント接続、Keychain / token、同期キュー・カーソル、検索索引は含めない。対象 Workspace に未文字起こし segmented audio があれば、文字起こしか明示破棄まで作成を拒否する。
チャットの Thread 台帳・Item 履歴とチャットの検索索引、Pi の実行再開用 session file は含めない。上書き復元は対象 Workspace の Thread を保持し、復元後も存在する Project との紐づけを残す。

## Google Drive と内蔵 Pi

設定のバックアップ一覧はマイドライブ直下の `Dahlia/Backup` から取得する。同名フォルダが複数ある場合は曖昧な宛先を選ばずエラーにする。
バックアップ一覧の取得経路と、app が Drive の OAuth token を持つかは未確定（[要約](summary.md#訂正と-export) は app が Drive の OAuth token を持たないとする）。Databricks アカウントでは Calendar と同じ Unity Gateway connection proxy を使い、接続名は `system_ai_agent_google_drive` とする。接続解除は Dahlia の読み取り利用を止め、Drive のファイルや別の MCP 接続は削除しない。

アップロード・フォルダ作成・Drive 上の削除をアプリの Drive client に持たせない。内蔵 Pi の `workspace-backup` skill は `dah_create_backup` tool を呼び（対象の `workspace_id` を必須引数とし、実行アカウントへの所属を検証する）、GUI と同じ `BackupService` の snapshot・原本収集・検証で作成する。Pi の作業フォルダに書き出したファイルを設定済み Google Drive MCP のローカルファイルアップロード機能で `My Drive/Dahlia/Backup` に配置する。外部書き込みは既存のチャット承認方針に従う。
必要な MCP 機能がなければローカル作成とアップロード失敗を区別して報告する。Unity Gateway connection で書き込まない。

Drive のファイルは選択時にダウンロードし、通常の import 検証を通してからローカルの復元用コピーへ追加する。
ローカルで作成・import した世代と上書き前の安全バックアップは引き続き保持し、ネットワークなしでも復元できる。
旧 Apple Archive（`.dahliabackup`）は一覧・import・復元の対象外とする。既存ファイル自体の削除・変換は行わない。

## Import と復元

展開は隔離した作業ディレクトリで行い、manifest にない entry、重複、リンク、パス逸脱、サイズ超過、hash 不一致を拒否する。復元先の原本を検証・確定した後にだけ DB を差し替える。

import は管理領域の一時 copy を integrity / metadata / schema / migration 履歴で検証して atomic に世代追加する。
未知の形式・schema、改変、追加 trigger / view、integrity 不良を拒否する。
既知の旧 schema は、その migration 時点の schema と履歴を検証して受け入れる。
復元時に管理領域の作業コピーだけを現行 schema へ migration し、元の世代は変更しない。

復元画面では含まれる Workspace を一覧表示し、各行で「復元しない」（初期値）または次の方法を選ぶ。
一部だけの選択と上書き・新規の混在を許可し、少なくとも一つ選択して1回の再起動で一括適用する。
同名の Workspace は名前と短縮 UUID で区別する。保存画面は現在の Workspace を初期選択し、すべて選択・解除を用意する。

- 元の Workspace を上書き: 同じ UUID のローカル Workspace が存在し、未処理音声がない場合だけ選べる。
  Workspace ID、現在のローカル出力先・AI 接続設定を維持し、保存内容を差し替える。
  復元後も同じ会議・録音セッション ID が残る場合は、現在の音声参照・範囲・保存進捗・整合性情報も保持する。
- 別 Workspace として復元: 名前を指定し、新しいローカル Workspace UUID と配下の ID を発行する。
  外部キー・多態参照・要約内のスクリーンショット参照も新しい ID へ書き換える。同名は許可する。
  接続、同期状態、出力先（要約の書き出し先参照を含む）は引き継がない。共有タグは名前で対応付け、既存タグや共有カレンダー情報は上書きしない。

復元による Server への操作・同期 transaction は生成しない。
バックアップは原本を内包するため、復元時にクラウドから画像を取得しない。

復元は再起動時、単一 process lock 取得後・通常 DB open 前に行う。録音・処理中には開始しない。
その時点の最新 DB を作業コピーに保存し、Workspace ごとに対象を再検証する。上書き前にその Workspace の安全 backup を作成し、Workspace ごとの transaction で復元する。
ある Workspace の検証・安全 backup・復元が失敗しても、他の Workspace は続行する。失敗した Workspace 内の変更は全て取り消し、成功した Workspace だけを適用する。
設定画面には各 Workspace の復元名・復元元 UUID の末尾8桁と成功・失敗理由を表示し、選択した復元元と対応付ける。全て失敗した場合は DB を置き換えない。
元 UUID・復元先 UUID の重複、空の要求、backup ファイル自体の検証・migration 失敗、最終 DB 適用失敗は全体を中止する。
他 Workspace のデータ、アカウント、同期状態、音声参照は保持する。
検証済み作業コピーを WAL checkpoint 後に適用し、元 DB を recovery として残す。
中断後の起動は recovery を優先する。検索索引は通常の索引処理で再構築する。

## 理由と制約

大容量音声は別 lifecycle のため DB snapshot に取り込まない。これだけでは完全な端末移行・音声 backup にならない。
復元時に既存音声ファイルを削除しない。外部 Markdown / 添付の書き換えも行わない。
復元対象以外の Workspace で、バックアップ後から再起動までに追加されたデータも最新 DB のコピーを通じて保持する。
Server canonical data は [同期契約](../shared/sync.md) の境界で扱い、backup restore を Server 削除の許可とみなさない。
既存 backup 世代や書き出し済み Markdown は本文 cache の容量管理で削除しない。

## 未適合・未検証

- 未確定: バックアップ一覧の取得経路と、app が Drive の OAuth token を持つかどうか。[要約](summary.md#訂正と-export) の 2026-11-11 規則は app が Drive の OAuth token を持たないとする。
