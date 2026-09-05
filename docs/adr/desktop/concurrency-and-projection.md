# 実行コンテキストと UI projection

対象: Desktop。採択: 2026-07-14〜07-24。現在の規範・適合状況は [Architecture](../../../ARCHITECTURE.md)、runtime flow は [音声・文字起こし](../../architecture/audio-transcription-data-flow.md) を正本とする。

## 録音と保存の分離

MainActor の store を debounce 保存すると描画停止が確定文字起こし保存まで止まるため、recognition → pipeline → persistence writer と UI projection を分離した。通常の逐次保存を一本化し、遅い UI snapshot が新しい翻訳を巻き戻す経路をなくす。

音声、確定文字起こし、確定翻訳、録音 range は UI の都合で捨てない。preview / preview translation は durable lane に入れず、nil の確定翻訳で保存済み値を消さない。正常停止は capture / recognition / pipeline / writer を順に drain し、pending flush 成功後だけ session / meeting を完了する。reset も flush 後。追記取消しは当該 session だけに限定する。

## 実行コンテキスト

機能ではなく処理段階を recording-critical、durable、interactive UI、rebuildable UI に分類する。小さく有界で I/O・外部 callback・長い lock 待機のない処理は同期のまま保ち、capture ごとの Task / actor hop を増やさない。

DB、disk、network、同期 OS query、入力依存の decode / parse は lifecycle を持つ MainActor 外の owner へ置く。Task で包んだだけで isolation が変わると考えず、actor を専用 thread / priority queue とも扱わない。mutable runtime は actor 等が所有し、ViewModel は要求と UI 状態を扱う。

操作受付と shell / progress は処理完了前に示す。user-initiated work を prefetch より優先し、不要処理を cancel、identity / generation で stale result を破棄する。queue ごとに容量、overflow の意味、cancel / finish owner、drain 範囲、最初の失敗の返却先を定める。

負荷時は不要な speculative work、再生成可能な表示の頻度・範囲・品質の順に下げる。interactive UI は進行を伝え、durable は順序を守って待つか明示失敗、recording-critical は UI を待たず容量超過を録音 error にする。全同期 API の actor 化や単一 global worker は、不要な lifecycle と priority inversion を増やすため採用しない。

## Transcript projection

確定 transcript は SQLite が正本。初期末尾200件、前後100件、保持最大300件の keyset pagination を採用し、cursor は startTime + ID。同時 page request は1件、反対端を削って semantic scroll anchor を維持する。追加読込失敗では既存表示を残す。summary / export は表示 window ではなく MainActor 外で DB 全文を読む。

UI backlog は reload required へ集約できるが、DB flush barrier 成功後だけ再読込する。失敗時は intent を保持して backoff retry。DB で復元不能な control state は対象別 latest-wins、最大50件として意味を保持する。履歴閲覧中の新規 event は viewport に挿入せず末尾への案内を出す。

停止時の UI worker 待ちは最大2秒、以後は再生成可能な projection の drain を打ち切れる。durable flush は打ち切らず、bounded store snapshot を保存 fallback に使わない。これは初期の UI 全件保持・停止時 snapshot 保存を置き換えた判断である。

## Markdown projection

raw Markdown を会話内容として完全に保持し、解析済み block だけを再生成可能にする。view ごとの actor で解析し、coordinator は実行中1件 + 最新待機1件。中間入力を FIFO 再生せず、block / 行の境界で cancel を確認する。

stream 中の全文を共有 cache に入れず、最終本文と整合した完了分だけを件数・UTF-8 byte cost で制限して保存する。既存 parse が raw prefix なら同一行 suffix を最終 block へ plain text で結合し、不可能・非 prefix・初回なら raw 全体に fallback。未変更の先頭 AttributedString を再利用する。

parse / cache eviction / cancel は raw を変更しない。停止・失敗後も受信済み本文を残し、transport と録音・保存を待たせない。単一の Foundation AttributedString 変換は途中 cancel できないが、view 別 owner に隔離する。本文・projection を診断へ送らない。

## 保証と未解決事項

保証対象は MainActor / UI の一時停止に対する進行であり、process-wide deadlock / crash / OOM / OS 停止まで actor 分離で防ぐとは扱わない。録音 helper process は再現・損失・復旧要件を計測してから別判断にする。

lossless persistence の unbounded backlog は未解決で、[Remediation Plan](../../../ARCHITECTURE.md#remediation-plan) の計測後に backpressure / recovery を決める。UI sink 停止中の保存進行、同時刻 pagination、世代変更、flush failure、停止順序、Markdown 集約と全文保持を検証する。個別の画像サイズ・cache 実装を横断規範にしない。
