# ADR 0019: Codex stdout を需要駆動で読み取る

## Status

Accepted; supersedes 0013, amends 0003; amended by 0020

## Date

2026-08-03

## Context

[ADR 0013](0013-expand-codex-stdout-burst-buffer.md) は、Codex app-server の stdout burst を行数上限付きの
メモリバッファへ先読みし、1,024 行を超えた時点で共有接続を破棄する方針を採用した。その後、pipe の読み取りを
`DispatchIO.read(length: Int.max)` と64チャンク上限の `AsyncStream` で中継する実装へ変更した。

`DispatchIO` の `lowWater` は1 byteであるため、子プロセスが短いJSONL行を連続して書くと、OSは1回の長寿命readを
多数の小さなcallbackへ分割しうる。この実装は保持バイト数や完全行数ではなくcallback由来のチャンク数を上限として
いたため、約60 KiB・1,000行という旧1,024行上限内の出力でも、actor側のconsumerが一時的に遅れるだけでoverflowに
なった。したがって行数上限の再調整では解決しない。

長寿命readを導入した際には、長さを指定した `DispatchIO.read` は指定byte数へ到達するまで完了せず、短いJSONL行を
即時処理できないためbackpressureには使えない、と判断していた。この判断は誤りだった。`lowWater: 1` を設定すると、
指定長へ到達する前でも到着済みdataが `done == false` のcallbackとして配送される。readの完了を待たずにその部分配送を
処理できる。

一方、子プロセスが改行を返さない場合は、需要駆動にしても単一行を完成させるためのメモリが入力に比例して増える。
JSON-RPC/JSONLとして妥当な通常出力と、framingが壊れた出力を区別する明示上限が必要である。

## Decision

- stdout は `receiveLine()` に未完のreaderがあり、完全行の手持ちがないときだけ読み進める。
- 1回の `DispatchIO.read` は最大64 KiBとする。`lowWater: 1` を維持し、`done == false` の部分配送も到着時点で解析する。
- 64 KiBを読み切った時点で未完のreaderが残っている場合だけ、次のread windowを開始する。完全行をreaderへ渡したか、
  後続の完全行を保持している間は新しいwindowを開始しない。これにより、読み手が遅いときはOS pipeへbackpressureを
  返す。
- 1 window内のcallbackは、ロック保護された `Data` relayへ順番どおり追記する。windowごとに1つのconsumerだけが
  relayをdrainし、callbackごとの `Task` やチャンク数制限付き `AsyncStream` は使わない。relayの保持量はcallback数では
  なくread windowの64 KiBで有界になる。
- 単一JSONL行の上限を新たに4 MiBとする。4 MiBちょうどは受理し、改行までに4 MiBを超えた場合はstdoutを停止して
  待機中readerを `outputLineTooLarge` で失敗させ、共有接続を破棄する。出力本文はログやSentryへ送らない。
- 完全行のFIFO、windowをまたぐ部分行、末尾改行なしのEOF、stderr tail、cancel、close、process終了の契約は維持する。
- 自動再送は追加しない。共有接続を破棄した結果は既存の明示的な失敗処理へ渡す。

## Consequences

- OSがstdoutを多数の小さなcallbackへ分割しても、配送回数だけを理由に正常な出力を失敗させない。
- 読み手が止まると、Dahliaのメモリへ無制限に先読みせず、最大64 KiBのread-aheadを経て子プロセス側へbackpressureが
  かかる。
- 旧1,024行上限を超えるburstも、consumerが継続する限りFIFOで処理できる。
- 改行なしの異常出力だけは新しい4 MiB上限でfail-closedになる。共有app-serverを使う進行中turnへ影響しうるが、
  framingが不明な接続を継続して別のresponseとして解釈することはない。
- consumerが長時間進まない場合、子プロセスはpipe書き込みで待つ可能性がある。pending RPCには既存のtransport timeoutが
  あり、Dahliaが正常出力を先読みoverflowとして即時破棄するよりも正確な失敗になる。

## Alternatives considered

### 行数上限またはチャンク数上限を拡張する

OSの配送分割とアプリが扱う完全行の数に安定した関係がない。値を増やしても同じ誤overflowが別のburstで再発し、
メモリ上限の意味も不明確なため却下した。

### 長寿命readと無制限relayを使う

consumer停止中も子プロセスの全出力をプロセス内へ取り込み続け、入力規模に応じてメモリ使用量が増えるため却下した。

### 64 KiB windowのcallbackごとにTaskを作る

callbackの分割数だけ非構造Taskが増え、actorへ到着する順序も別途保証する必要がある。window単位のrelayと単一consumerで
同じ即時性を保てるため却下した。
