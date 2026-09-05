# Codex runtime と stdio

対象: Desktop 内蔵 Codex。採択: 2026-07-15〜08-03。Dahlia Server とは別の子 process。

## 所有境界

アプリ共有の長寿命 app-server と dispatcher が認証、model catalog、request / turn、process cleanup を所有する。summary の prompt / schema / decode と chat の履歴 / stream 変換は上位 service に残す。[Account context](accounts.md#codex-account-context) の切替では進行中操作を drain して home を変え、同時 process は1つにする。

arm64 公式 native release と SHA-256 を固定し、実行対象は bundle の `Contents/Helpers/codex` のみ。外部 PATH、Bun/npm、source build に依存しない。upstream 署名除去後に検証し、最終 bundle は Developer ID / Hardened Runtime で署名する。JIT entitlement は helper だけ。専用 CODEX_HOME は起動前に0700で作り、`~/.codex` をコピー・参照しない。

## Lifecycle と失敗半径

同時 start は同じ bootstrap に合流し、connection ごとに initialize → initialized を一度だけ行う。request ID、thread / turn ID、connection generation で順不同 response と早着 notification を扱い、古い failure が新しい接続を停止しないようにする。

- 通常 request の cancel / timeout は該当 waiter だけを完了し、健康な接続と他 turn を維持する。期限は [AI timeout](../shared/ai-timeouts.md) に従う。
- bootstrap failure、EOF、process exit、protocol violation は全 request / turn / login waiter と subscriber を error 完了し、close 後だけ再起動する。壊れた JSONL を読み飛ばさず、未知 server request にも error 応答する。
- 要約 cancel / timeout は判明済み turn を一度 interrupt して unsubscribe。終了済み process を cleanup のために起動せず、生成の自動再送もしない。completion 未受信でも upstream 完了済みの可能性があるためである。
- shutdown は新規 start を拒否し、app は terminateLater で cleanup を待つ。stdin close、猶予後の SIGTERM / SIGKILL、stdio drain / reap を所有する。

## Stdout backpressure

`receiveLine()` の未完 reader があり、完全行の手持ちがない場合だけ、最大64 KiBの DispatchIO read を開始する。lowWater 1で部分配送を即時解析し、window ごとの lock-protected Data relay と単一 consumer で FIFO を保つ。callback ごとの Task や callback 数で上限を決める stream は使わない。

完全行を渡した後や後続の完全行を保持中は新しい window を開始せず、consumer 停止時は OS pipe に backpressure を返す。単一 JSONL 行上限は **4 MiB + 接続中の送信済み最大 JSONL 行 byte 数**。送信開始前に単調増加させ、入力の即時 echo を受理する。request 本文の追加保持はせず、接続終了まで上限は縮めない。

超過は `outputLineTooLarge` で reader と共有接続を失敗させる。window をまたぐ部分行、改行なし EOF、cancel / close を処理し、stderr は独立して drain、末尾16 KiBだけをメモリ保持する。協調スレッドで同期 read/write/wait しない。

## 利用プロファイル

要約は ephemeral、temporary cwd、read-only / never、必須 output schema、全 tool / MCP / skill 無効。画像非対応・能力不明ならテキストで継続し、全結果で temporary cwd を削除する。

chat は persistent、schema なし Markdown、Codex rollout を履歴の正本とする。Vault 別 cwd / source kind で履歴を絞り、session 内の turn は1件。delta は最終本文で整合し、停止後も受信済み本文を残す。権限は [Chat approval](chat-approval.md)、描画は [projection](concurrency-and-projection.md#markdown-projection) を参照する。

model catalog は pagination し、認証変更・transport reset で cache を無効化する。一時的な model fallback と保存値を分け、空一覧・失敗で model / effort 設定を上書きしない。

## 経緯と検証

256行 → 1024行の先読み拡大でも OS callback 分割による誤 overflow は防げなかったため、byte window と需要駆動へ変更した。固定4 MiB行上限も画像 input の正常な echo を拒否したため、client 入力に連動させた。無制限 buffer と画像一時ファイル化は、それぞれメモリ無制限化と別の所有・cleanup 契約を持ち込むため採用しない。

consumer 停止時の pipe 待機と protocol failure の全 turn への影響は残る。fake transport / clock で順不同、早着、timeout、cancel、shutdown を検証し、実 process では一時 home を使って signal / stdio / reap を確認する。binary 更新時は対象版の生成 schema と署名を確認する。

prompt、画像、文字起こし、chat、生成結果、request / response body、動的上限値を log / Sentry に送らない。cancel・未ログイン・helper 未同梱は期待状態として扱う。
