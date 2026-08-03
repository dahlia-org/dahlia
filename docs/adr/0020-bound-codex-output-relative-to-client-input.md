# ADR 0020: Codex stdout の単一行上限をclient入力に応じて拡張する

## Status

Accepted; amends 0019 and 0003

## Date

2026-08-03

## Context

[ADR 0019](0019-pull-codex-stdout-with-backpressure.md) は、改行のない壊れたstdoutによる無制限なメモリ使用を防ぐため、
単一JSONL行へ4 MiBの固定上限を導入した。しかしCodex app-serverは、`turn/start`で受け取ったuser inputを
`item/started`と`item/completed`のuser messageとしてclientへエコーする。

Dahliaの要約とチャットは画像をbase64 data URIとして同じJSONL requestへ含める。複数画像を含む正常なrequestと、
それを包むitem lifecycle notificationは4 MiBを超えうる。固定上限はframing異常ではない正常なnotificationを拒否し、
共有接続と進行中turnを `outputLineTooLarge` で失敗させていた。

一方、上限を削除すると、子プロセスが改行を返さない場合の保持量が再び入力に比例して無制限になる。clientが送信した
入力のエコーを受理しつつ、接続ごとの明示的な上限を維持する必要がある。

## Decision

- 単一JSONL行の基本上限は4 MiBのまま維持する。
- 接続中にclientが送信した最大JSONL行のbyte数を基本上限へ加え、その値を接続中の単一出力行上限とする。
- 上限は送信開始前にactor内で単調増加させ、app-serverが入力を即座にエコーしても先に失敗しないようにする。
- 上限を超えたstdoutはADR 0019と同様に停止し、待機中readerを `outputLineTooLarge` で失敗させて共有接続を破棄する。
- requestおよびresponse本文、画像data URI、算出した上限値はログまたはSentryへ送らない。

## Consequences

- 大容量のclient入力を包む正常なitem lifecycle notificationを受理できる。
- 接続中の保持上限は「4 MiB + 送信済み最大JSONL行」に限定され、無制限なread-aheadは再導入しない。
- 一度大きなrequestを送ると、その接続が終了するまで上限は縮小しない。上限値だけを保持し、request本文は追加保持しない。
- client入力に由来しない異常なstdoutが動的上限を超えた場合は、従来どおり進行中turnを含む共有接続が失敗する。

## Alternatives considered

### 固定上限だけを拡張する

正常な入力サイズに根拠づけられず、値を超える有効な画像requestで再発する。必要以上に大きな固定値は小さなrequestしか
送っていない接続でも同じメモリ量を許容するため採用しない。

### 単一行上限を削除する

改行のない壊れたstdoutを入力サイズに関係なく保持し続けるため採用しない。

### 画像を一時ファイル参照へ変更する

wire上のdata URIは削減できるが、要約とチャットの入力契約、temporary fileの所有権、cleanup、sandbox accessを同時に
変更する必要がある。client入力のエコーという一般的なprotocol特性への対策にならないため、この修正には含めない。
