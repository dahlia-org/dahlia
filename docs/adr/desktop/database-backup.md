# Vault archive backup / restore

対象: Desktop。採択: 2026-07-18。保管庫単位の保存・復元へ更新: 2026-09-06。

## 世代と対象

Local Account 配下の複数の保管庫を選択して一つの gzip 圧縮 tar（`.tar.gz`） を Application Support/Dahlia/Backups にユーザー削除まで保持する。自動で世代数を減らさない。
現行形式の manifest と各 DB snapshot に元の保管庫 UUID・名前の一覧、世代 UUID、日時、schema / migration、app version/build、理由を埋め込む。
単一の DB snapshot から選択した全保管庫を抽出し、途中で失敗した世代は公開しない。
現行 manifest を持つ tar.gz だけを読み込み・復元の対象とする。

対象は選択した保管庫の DB 内データと参照関係。Project 階層、会議、文字起こし・翻訳、session timeline、要約、
files の metadata、会議との紐付け、スクリーンショットの OCR / caption を含む。原本は `files/{fileId}/original`、DB は `database.sqlite` として格納し、`manifest.json` に各 entry のサイズと SHA-256 を記録する。
Server Account の保管庫とその未送信画像は対象外。Local Account の対象保管庫の原本は FileStore から取り込む。画面の選択肢と作成元 snapshot の所属を検証し、
Server Account の保管庫を一つでも含む作成要求は世代を公開せず拒否する。端末固有の画像ファイル参照は含めない。
共有タグ・カレンダー情報は対象会議から参照されるものだけを保存する。
明示した対象テーブルから新しい DB へコピーするため、他保管庫の内容は含まれない。原文・要約・OCR / caption の専用本文テーブルもコピーし、親 metadata に対応する本文の欠損があれば世代の公開・復元を拒否する。本文の保持状態や同期 state はコピーしない。
音声本体・参照、Vault Markdown / 添付、端末の出力先、UserDefaults、アカウント接続、Keychain / token、同期キュー・カーソル、
検索索引は含めない。対象保管庫に未文字起こし segmented audio があれば、文字起こしか明示破棄まで作成を拒否する。
チャットの Thread 台帳・Item 履歴とチャットの検索索引、Pi の実行再開用 session file は含めない。上書き復元は対象保管庫の Thread を保持し、復元後も存在する Project との紐づけを残す。

## Google Drive と内蔵 Pi

設定のバックアップ一覧はマイドライブ直下の `Dahlia/Backup` から取得する。同名フォルダが複数ある場合は曖昧な宛先を選ばずエラーにする。
Google Drive は Calendar と別の Keychain セッションで `drive.readonly` を認証する。Databricks アカウントでは Calendar と同じ
Unity Gateway connection proxy を使い、接続名は `system_ai_agent_google_drive` とする。接続解除は Dahlia の読み取り利用を止め、Drive のファイルや別の MCP 接続は削除しない。

アップロード・フォルダ作成・Drive 上の削除をアプリの Drive client に持たせない。内蔵 Pi の `workspace-backup` skill は現在のチャットの Local Workspace に限定した
`dahlia_create_backup` tool を呼び、GUI と同じ `BackupService` の snapshot・原本収集・検証で作成する。Pi の作業フォルダに書き出したファイルを
設定済み Google Drive MCP のローカルファイルアップロード機能で `My Drive/Dahlia/Backup` に配置する。外部書き込みは既存のチャット承認方針に従う。
必要な MCP 機能がなければローカル作成とアップロード失敗を区別して報告する。Unity Gateway connection で書き込まない。

Drive のファイルは選択時にダウンロードし、通常の import 検証を通してからローカルの復元用コピーへ追加する。
ローカルで作成・import した世代と上書き前の安全バックアップは引き続き保持し、ネットワークなしでも復元できる。
旧 Apple Archive（`.dahliabackup`）は一覧・import・復元の対象外とする。既存ファイル自体の削除・変換は行わない。

## Import と復元

展開は隔離した作業ディレクトリで行い、manifest にない entry、重複、リンク、パス逸脱、サイズ超過、hash 不一致を拒否する。復元先の原本を検証・確定した後にだけ DB を置き換える。

import は管理領域の一時 copy を integrity / metadata / schema / migration 履歴で検証して atomic に世代追加する。
未知の形式・schema、改変、追加 trigger / view、integrity 不良を拒否する。
既知の旧 schema は、その migration 時点の schema と履歴を検証して受け入れる。
復元時に管理領域の作業コピーだけを現行 schema へ migration し、元の世代は変更しない。

復元画面では含まれる保管庫を一覧表示し、各行で「復元しない」（初期値）または次の方法を選ぶ。
一部だけの選択と上書き・新規の混在を許可し、少なくとも一つ選択して1回の再起動で一括適用する。
同名保管庫は名前と短縮 UUID で区別する。保存画面は現在の保管庫を初期選択し、すべて選択・解除を用意する。

- 元の保管庫を上書き: 同じ UUID のローカル保管庫が存在し、未処理音声がない場合だけ選べる。
  保管庫 ID、現在のローカル出力先・AI 接続設定を維持し、保存内容を置き換える。
  復元後も同じ会議・録音セッション ID が残る場合は、現在の音声参照・範囲・保存進捗・整合性情報も保持する。
- 別保管庫として復元: 名前を指定し、新しいローカル保管庫 UUID と配下の ID を発行する。
  外部キー・多態参照・要約内のスクリーンショット参照も置き換える。同名は許可する。
  接続、同期状態、出力先（要約の書き出し先参照を含む）は引き継がない。共有タグは名前で対応付け、既存タグや共有カレンダー情報は上書きしない。

Server Account の保管庫への上書きは拒否する。復元による Server への操作・同期 transaction は生成しない。
バックアップは原本を内包するため、復元時にクラウドから画像を取得しない。

復元は再起動時、単一 process lock 取得後・通常 DB open 前に行う。録音・処理中には開始しない。
その時点の最新 DB を作業コピーに保存し、保管庫ごとに対象を再検証する。上書き前にその保管庫の安全 backup を作成し、保管庫ごとの transaction で復元する。
ある保管庫の検証・安全 backup・復元が失敗しても、他の保管庫は続行する。失敗した保管庫内の変更は全て取り消し、成功した保管庫だけを適用する。
設定画面には各保管庫の復元名・復元元 UUID の末尾8桁と成功・失敗理由を表示し、選択した復元元と対応付ける。全て失敗した場合は DB を置き換えない。
元 UUID・復元先 UUID の重複、空の要求、backup ファイル自体の検証・migration 失敗、最終 DB 適用失敗は全体を中止する。
他保管庫のデータ、アカウント、同期状態、音声参照は保持する。
検証済み作業コピーを WAL checkpoint 後に適用し、元 DB を recovery として残す。
中断後の起動は recovery を優先する。検索索引は通常の索引処理で再構築する。

## 理由と制約

大容量音声は別 lifecycle のため DB snapshot に取り込まない。これだけでは完全な端末移行・音声 backup にならない。
復元時に既存音声ファイルを削除しない。外部 Markdown / 添付の書き換えも行わない。
復元対象以外の保管庫で、バックアップ後から再起動までに追加されたデータも最新 DB のコピーを通じて保持する。
Server canonical data は [同期契約](../shared/sync.md) の境界で扱い、backup restore を Server 削除の許可とみなさない。


Server Account の本文部分保持で backup の対象は広げない。Local Account へ移す場合は、metadata 同期と全本文・画像原本の取得を完了してから所属を変更する。途中失敗した接続や未送信 queue は保持し、不完全な working copy を Local Account の完全な backup として扱わない。既存 backup 世代や書き出し済み Markdown は本文 cache の容量管理で削除しない。
