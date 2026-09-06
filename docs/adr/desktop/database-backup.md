# SQLite backup / restore

対象: Desktop。採択: 2026-07-18。保管庫単位の保存・復元へ更新: 2026-09-06。

## 世代と対象

保管庫を選択して SQLite backup を Application Support/Dahlia/Backups にユーザー削除まで保持する。自動で世代数を減らさない。
形式 v2 の各 snapshot に元の保管庫 UUID・名前、世代 UUID、日時、schema / migration、app version/build、理由を埋め込む。
旧形式 v1 は読み込み・復元に対応しない。旧世代は削除できる。

対象は選択した保管庫の DB 内データと参照関係。Project 階層、会議、文字起こし・翻訳、session timeline、要約、
スクリーンショット本体と OCR / caption、顧客情報を含む。共有タグ・カレンダー情報は対象会議から参照されるものだけを保存する。
明示した対象テーブルから新しい DB へコピーするため、他保管庫の内容は含まれない。
音声本体・参照、Vault Markdown / 添付、端末の出力先、UserDefaults、アカウント接続、Keychain / token、同期キュー・カーソル、
検索索引は含めない。対象保管庫に未文字起こし segmented audio があれば、文字起こしか明示破棄まで作成を拒否する。

## Import と復元

import は管理領域の一時 copy を integrity / metadata / schema / migration 履歴で検証して atomic に世代追加する。
未知の形式・schema、改変、追加 trigger / view、integrity 不良を拒否する。
既知の旧 schema を持つ v2 は、その migration 時点の schema と履歴を検証して受け入れる。
復元時に管理領域の作業コピーだけを現行 schema へ migration し、元の世代は変更しない。

復元方法は次の二つ。

- 元の保管庫を上書き: 同じ UUID のローカル保管庫が存在し、未処理音声がない場合だけ選べる。
  保管庫 ID、現在のローカル出力先・AI 接続設定を維持し、保存内容を置き換える。
  復元後も同じ会議・録音セッション ID が残る場合は、現在の音声参照・範囲・保存進捗・整合性情報も保持する。
- 別保管庫として復元: 名前を指定し、新しいローカル保管庫 UUID と配下の ID を発行する。
  外部キー・多態参照・要約内のスクリーンショット参照も置き換える。同名は許可する。
  接続、同期状態、出力先（要約の書き出し先参照を含む）は引き継がない。共有タグは名前で対応付け、既存タグや共有カレンダー情報は上書きしない。

同期保管庫のローカル working copy も保存できるが、Server の未取得データまで含む完全な Server backup ではない。
同期保管庫への上書きは拒否し、新しいローカル保管庫としてのみ復元する。Server への操作・同期 transaction は生成しない。

復元は再起動時、単一 process lock 取得後・通常 DB open 前に行う。録音・処理中には開始しない。
その時点の最新 DB を作業コピーに保存し、上書きの場合は対象保管庫の安全 backup を作成してから、対象内容だけを transaction で置き換える。
安全 backup の失敗では復元を中止する。他保管庫のデータ、アカウント、同期状態、音声参照は保持する。
検証済み作業コピーを WAL checkpoint 後に適用し、元 DB を recovery として残す。
中断後の起動は recovery を優先する。検索索引は通常の索引処理で再構築する。

## 理由と制約

大容量音声は別 lifecycle のため DB snapshot に取り込まない。これだけでは完全な端末移行・音声 backup にならない。
復元時に既存音声ファイルを削除しない。外部 Markdown / 添付の書き換えも行わない。
復元対象以外の保管庫で、バックアップ後から再起動までに追加されたデータも最新 DB のコピーを通じて保持する。
Server canonical data は [同期契約](../shared/sync.md) の境界で扱い、backup restore を Server 削除の許可とみなさない。
