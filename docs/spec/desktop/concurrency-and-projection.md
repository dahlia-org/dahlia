# 実行コンテキストと UI projection

対象: Desktop。採択: 2026-07-14〜07-24。現在の規範・適合状況は [Architecture](../../../ARCHITECTURE.md)、runtime flow は [音声・文字起こし](../../architecture/audio-transcription-data-flow.md) を正本とする。

## 録音と保存の分離

MainActor の store を debounce 保存すると、描画停止が確定文字起こしの保存まで止まる。そのため recognition → pipeline → persistence writer と UI projection を分離する。通常の逐次保存は一本化し、遅い UI snapshot が新しい翻訳を巻き戻さない。

音声、確定文字起こし、確定翻訳、録音 range は UI の都合で捨てない。preview / preview translation は durable lane に入れず、nil の確定翻訳で保存済み値を消さない。正常停止は capture / recognition / pipeline / writer を順に drain し、pending flush 成功後だけ session / meeting を完了する。reset も flush 後。追記取消しは当該 session だけに限定する。

## 実行コンテキスト

機能ではなく処理段階を recording-critical、durable、interactive UI、rebuildable UI に分類する。小さく有界で I/O・外部 callback・長い lock 待機のない処理は同期のまま保ち、capture ごとの Task / actor hop を増やさない。

DB、disk、network、同期 OS query、入力依存の decode / parse は lifecycle を持つ MainActor 外の owner へ置く。`Task.detached` は MainActor を避ける一般的な手段にせず、新しい呼び出しは lint で拒否する。DB の読み取りは GRDB の非同期読み取りを使う。Task で包んだだけで isolation が変わると考えず、actor を専用 thread / priority queue とも扱わない。mutable runtime は actor 等が所有し、ViewModel は要求と UI 状態を扱う。

操作受付と shell / progress は処理完了前に示す。user-initiated work を prefetch より優先し、不要処理を cancel、identity / generation で stale result を破棄する。queue ごとに容量、overflow の意味、cancel / finish owner、drain 範囲、最初の失敗の返却先を定める。

負荷時は不要な speculative work、再生成可能な表示の頻度・範囲・品質の順に下げる。interactive UI は進行を伝え、durable は順序を守って待つか明示失敗、recording-critical は UI を待たず容量超過を録音 error にする。

## Transcript projection

確定 transcript は SQLite が正本。初期末尾200件、前後100件、保持最大300件の keyset pagination を採用し、cursor は startTime + ID。同時 page request は1件、反対端を削って semantic scroll anchor を維持する。追加読込失敗では既存表示を残す。summary / export は表示 window ではなく MainActor 外で DB 全文を読む。

UI backlog は reload required へ集約できるが、DB flush barrier 成功後だけ再読込する。失敗時は intent を保持して backoff retry。DB で復元不能な control state は対象別 latest-wins、最大50件として意味を保持する。履歴閲覧中の新規 event は viewport に挿入せず末尾への案内を出す。

停止時の UI worker 待ちは最大2秒、以後は再生成可能な projection の drain を打ち切れる。durable flush は打ち切らず、bounded store snapshot を保存 fallback に使わない。

文字起こしタブの行は `TranscriptWebSurface` が WebContent プロセスで描画し、その layout は MainActor を止めない。Swift は `TranscriptStore` の表示範囲と前回送った内容の差分（並び順と、新しい行・変わった行）だけを送る。送信は表示面ごとに1件で、Web がその更新を描いたフレームで返す `presented` を受けるまで次を送らない。待つ間の変更は次の差分にまとまるので、未送信の量は表示範囲を超えない。隠れたページはフレームを描かないため、DOM へ反映した時点で返す。表示中に2秒返らないか WebContent が終了した場合は読み込み直して全行を送り直し、`hangProcess=web` として報告する。表示範囲の持ち主（Meeting）が変わったら全行を送り直す。

## Markdown projection

raw Markdown を会話内容として完全に保持し、解析済み block だけを再生成可能にする。view ごとの actor で解析し、coordinator は実行中1件 + 最新待機1件。中間入力を FIFO 再生せず、block / 行の境界で cancel を確認する。

stream 中の全文を共有 cache に入れず、最終本文と整合した完了分だけを件数・UTF-8 byte cost で制限して保存する。既存 parse が raw prefix なら同一行 suffix を最終 block へ plain text で結合し、不可能・非 prefix・初回なら raw 全体に fallback。未変更の先頭 AttributedString を再利用する。

本文の `NSTextView` は、実際に置かれた幅（最初の有効な提案、以後はフレーム）でだけ組版する。SwiftUI は1回の layout で幅 0 や中間幅でも高さを問い合わせるため、それ以外の幅には現在の layout から面積を保った推定を返し、layout を捨てない。捨てると会話内の全メッセージが更新のたびに組版し直される（2026-11-20 計測、50 KB の stream で 30 万回、停止合計 115 秒）。

parse / cache eviction / cancel は raw を変更しない。停止・失敗後も受信済み本文を残し、transport と録音・保存を待たせない。単一の Foundation AttributedString 変換は途中 cancel できないが、view 別 owner に隔離する。本文・projection を診断へ送らない。

## 保証の範囲

保証対象は MainActor / UI の一時停止に対する進行。process-wide deadlock / crash / OOM / OS 停止まで actor 分離で防ぐとは扱わない。個別の画像サイズ・cache 実装は横断規範にしない。

## 未適合・未検証

- 未確定: lossless persistence の unbounded backlog は未解決。[Remediation Plan](../../../ARCHITECTURE.md#remediation-plan) の計測後に backpressure / recovery を決める。
- 未確定: 録音 helper process の要否。再現・損失・復旧要件を計測してから別判断にする。
- 未検証: UI sink 停止中の保存進行、同時刻 pagination、世代変更、flush failure、停止順序、Markdown 集約と全文保持。
- 未検証: ライブ字幕とライブ文字起こしの応答性は、録音を伴うため実機で計測していない。
- 未適合: 極端に長い応答（50 KB を6件）が並ぶ会話は、開いた直後の初回 layout で約1秒止まる（2026-11-20 計測）。

## 却下した案

- 全同期 API の actor 化: 不要な lifecycle と priority inversion を増やすため。
- 単一 global worker: 不要な lifecycle と priority inversion を増やすため。
- AI チャットの会話全体の WebView 化: 停止の原因は組版をやり直す1箇所の不具合で、承認・ツール記録・添付を含む会話の部品を作り直す危険に見合わない（2026-11-20）。
- 新規 Meeting 作成（`createEmptyMeeting`、`materializeDraftMeeting`）の DB 書き込みの非同期化: `DatabasePool` で待つのは実行中の書き込み1件だけで、呼び出し元が同期で受け取る ID と失敗時の巻き戻しの作り直しに見合わない（2026-11-20）。
- `CaptionViewModel` の分割: 頻繁に変わる値は既に別の store にあり、分割の効果を示す計測結果がない（2026-11-20）。
- サイドバーの `NSTableView` 化: 行のフレーム追跡と行ごとの設定監視を外した `List` で、250 ms 以上の停止がなくなった。予定・Project の開閉・複数選択・名前変更の作り直しに見合わない（2026-11-20）。
