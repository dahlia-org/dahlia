# ADR-0006: 大量文字起こしを bounded projection と keyset pagination で表示する

## Status

Accepted

## Date

2026-07-17

## Context

ADR-0002 は録音・認識・永続化を MainActor から分離し、文字起こし表示を有界な window にする方針を定めた。しかし実装では `TranscriptStore` がミーティング全件を保持し、スクロールのたびに全配列から表示 window の anchor を検索していた。履歴ミーティングの初期ロードも SQLite から全セグメントを読み込んでいたため、データ量に比例して DB 読み込み、モデル変換、MainActor への代入、SwiftUI の差分計算が増える。

また ADR-0002 は UI lane の確定イベントを欠落させず、確定セグメントを UI store にも全件保持するとした。この規則は durable persistence には必要だが、再読込可能な表示 projection に適用すると、MainActor が長時間停止した際に UI queue と store が無制限に増える。

## Decision

SQLite を確定文字起こしの durable source of truth とし、`TranscriptStore` は現在の viewport 周辺だけを保持する再読込可能な projection とする。ADR-0002 の録音 runtime と persistence lane の分離は維持し、UI projection に関する全件保持規則だけを本 ADR で置き換える。

### DB pagination

- 確定セグメントは `(meetingId, isConfirmed, startTime, id)` の index を使う。
- 初期表示は末尾 200 件、前後の追加読込は 100 件とする。
- cursor は `(startTime, id)` とし、`OFFSET` は使わない。同一 `startTime` の行も `id` で安定順序を持つ。
- 全文を必要とする要約・export は表示 store を参照せず、DB から MainActor 外で全件取得する。

### UI projection

- `TranscriptStore` が保持する確定セグメントは最大 300 件とする。preview は音源ごとの最新 1 件だけを追加で保持する。
- ページを一方向へ追加したときは反対端を削り、viewport の semantic view ID を維持する。
- meeting 切替時は generation を更新し、古い非同期 page 結果を破棄する。page request は同時に 1 件だけとする。
- SwiftUI は `LazyVStack` と semantic scroll target ID を使用する。絶対 content offset、全件配列の anchor 検索、通常 pagination 中の中央 spinner は使用しない。
- 初期 page のみ中央 loading を表示する。追加読込に失敗しても既存内容を保持し、再試行可能なエラーを表示する。

### UI lane compaction

- persistence lane の確定・翻訳イベントは引き続き欠落禁止とする。
- UI lane の未配送 projection event は上限を持ち、上限超過時は古い projection event を `reload required` に集約できる。
- failure や preview clear、preview translation など SQLite から復元できない制御イベントは、意味上の対象ごとに latest-wins で集約する。failure は session / 音源単位の最新状態を保持し、UI lane 全体の上限超過時も最新の制御状態だけを最大 50 件保持する。
- reload は、それ以前の persistence event の flush barrier が成功した後、SQLite の最新末尾 page から行う。flush が一時的に失敗した場合は reload intent を保持し、指数的 backoff で再試行する。したがって UI lane の集約は durable data の欠落を意味しない。
- 録音中に履歴位置を見ている場合、新しい確定イベントを viewport へ挿入せず「新しい文字起こしあり」として末尾へ再読込できるようにする。
- stop 時に UI worker を待つ時間は最大 2 秒とする。UI が復帰しなければ UI projection の drain を打ち切り、persistence lane の完了を優先する。未表示分は SQLite から再構築できる。

### Persistence completion

- `TranscriptPersistenceWriter` は失敗した durable event を actor 内に保持し、指数的 backoff を伴う次回 persist または stop で再試行する。
- stop は pipeline を drain した後に writer の pending event を flush し、その成功後だけ recording session と meeting を完了する。
- bounded な UI store snapshot を停止時の永続化 fallback として使用しない。
- reset は pending event の flush に成功した後だけ追跡状態を破棄する。

## Invariants

- 音声、確定文字起こし、確定翻訳、録音 range は UI 負荷を理由に破棄しない。
- UI のメモリ量と SwiftUI の行数は、ミーティング全体のセグメント数に比例して増えない。
- 同一時刻の行を含め、前後 pagination に欠落・重複がない。
- 古い page request や meeting の結果が現在の表示を上書きしない。
- persistence flush に失敗した recording session は完了扱いにしない。
- UI worker の停止や遅延は persistence lane の drain を無期限に待たせない。
- 要約と export は表示中の 300 件だけでなく、DB にある全文を使用する。

## Consequences

良い影響:

- 初期表示、スクロール、SwiftUI 差分計算の上限が固定され、大量文字起こしでも MainActor を長時間占有しにくい。
- UI 停止時も persistence は lossless のまま、復帰後に古い UI event を大量再生しない。
- DB query は深い履歴位置でも `OFFSET` に比例して遅くならない。

トレードオフ:

- viewport の前後で DB query が発生し、page cursor、generation、anchor 復元の状態管理が必要になる。
- 表示 store は全文ではないため、全文利用箇所を DB query と明確に分離する必要がある。
- UI event の集約後は一時的に最新表示へ再同期するまで projection が古い場合がある。

## Relationship to ADR-0002

ADR-0002 の capture、recognition、persistence を MainActor から分離する決定は有効である。本 ADR は次の部分だけを supersede する。

- UI lane の確定イベントを無制限に保持すること。
- 確定セグメントを `TranscriptStore` に全件保持すること。
- 停止時に UI store の全 snapshot を persistence fallback とすること。

durable persistence lane の欠落禁止と停止時 drain は引き続き ADR-0002 に従う。
