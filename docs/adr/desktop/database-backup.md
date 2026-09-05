# SQLite backup / restore

対象: Desktop。採択: 2026-07-18。

## 世代と対象

SQLite backup を Application Support/Dahlia/Backups にユーザー削除まで保持し、自動で世代数を減らさない。各 snapshot に形式 version、世代 UUID、日時、schema / migration、app version/build、理由を埋め込む。

対象は SQLite と transcript / session timeline。音声参照は snapshot から除き、音声本体、Vault Markdown / 添付、UserDefaults、Keychain / token はコピーしない。未文字起こし segmented audio があれば、文字起こしか明示破棄まで作成・復元を拒否する。読めない旧 single-file 参照は backup から除く。

## Import と復元

import は管理領域の一時 copy を integrity / metadata / migration 履歴で検証して atomic に世代追加する。復元前には現在 DB の安全 backup を作る。既知の旧 schema は staging で migration、未知の新 schema、改変、追加 trigger / view、integrity 不良は拒否する。

復元は再起動時、単一 process lock 取得後・通常 DB open 前に行う。WAL checkpoint 後、元 DB を recovery として残して検証済み copy へ切り替える。中断後の起動は recovery を優先し、再試行可能な状態へ戻す。

## 理由と制約

大容量音声は別 lifecycle のため DB snapshot に取り込まない。これだけでは完全な端末移行・音声 backup にならず、復元には再起動が必要で録音中には始められない。世代容量は利用者が管理する。Server canonical data と復元後の整合は [同期契約](../shared/sync.md) の境界で扱い、DB restore を Server 削除の許可とみなさない。
