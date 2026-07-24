# ADR-0009: 実行コンテキストと負荷縮退順序を定める

## Status

Accepted

この ADR は、[ADR-0002](0002-isolate-recording-critical-path-from-main-actor.md) のうち、
同期／非同期の一般的な選択基準と、個別実装に依存した表示負荷の規則を置き換える。
録音イベントを UI lane と persistence lane に分離する決定自体は引き続き ADR-0002 に従う。
実装の未適合箇所と修正完了条件は
[ARCHITECTURE.md の Conformance Status と Remediation Plan](../../ARCHITECTURE.md#conformance-status)で追跡する。

## Date

2026-07-24

## Context

ADR-0002 により、録音、認識、確定文字起こしの保存は MainActor の表示処理から分離された。
その後、画像 decode、長文 layout、streaming Markdown、OS query などを MainActor 外へ出すために actor や
`async` 関数が増えた。

しかし、同期 API であることは処理が重いことを意味せず、`async` であることも MainActor を占有しないことを意味しない。
軽量で上限が明確な処理まで非同期化すると、actor hop、task lifecycle、停止順序が増え、録音処理の理解と検証を難しくする。

反対に、重い処理を一つの actor へ直列化すれば MainActor の直接占有は避けられるが、prefetch や off-screen work が
ユーザー操作を待たせる priority inversion を起こし得る。個別の View や画像形式だけを対象にした規則では、
新しい UI workload が追加されるたびに同じ問題を繰り返す。

録音データの保全と UI の応答性は、どちらも重要だが異なる品質軸である。Dahlia には、処理の種類に依存しない
実行コンテキストの判断基準と、負荷時に何から縮退させるかという共通方針が必要である。

## Decision

### 機能ではなく処理段階を分類する

各処理段階を次の四つに分類する。

- `recording-critical`: capture callback、timestamp 付与、audio routing、writer queue への受け渡し。
- `durable`: immutable audio segment、確定文字起こし、確定翻訳、ユーザーが確定した保存操作。
- `interactive UI`: 選択、画面遷移、開閉、操作開始のフィードバック。
- `rebuildable UI`: preview、表示 window、cache、prefetch、再生成可能な解析・描画結果。

一つの機能を一つの class に固定しない。たとえば詳細表示では、画面の開閉は `interactive UI`、
表示用 decode は `rebuildable UI`、書き出し先への保存は `durable` である。

### 同期処理を維持する条件

次を満たす処理は同期のまま保つ。

- 小さく、入力サイズに依存せず、実行時間の上限が明確である。
- I/O、外部 callback、OS 応答、長時間の lock 待機を含まない。
- 非同期 lifecycle や別の isolation domain を必要としない。

capture callback 内の timestamp 付与と routing は、この条件を満たすよう実装し、callback ごとの `Task` や
actor hop を追加しない。lock は小さな状態更新だけを保護し、lock 内で I/O や外部 callback を実行しない。

### MainActor 外へ置く条件

次のいずれかに該当する処理は MainActor 外の、lifecycle を所有された service または worker で実行する。

- database、disk、network、同期 OS query を待つ。
- decode、parse、layout preparation など、入力サイズに応じて CPU またはメモリ使用量が増える。
- 長寿命な可変 runtime を所有し、順序保証または停止時の drain が必要である。

単に `Task {}` で包まず、呼び出し元と task closure の isolation を確認する。`Task.detached` を一般的な
MainActor 回避策にはせず、cancellation、終了、エラーを追跡できる owner を持たせる。

actor は状態と順序の所有境界として使う。actor は専用 thread や priority queue ではないため、
異なる優先度の workload を一つの actor に無差別に直列化しない。

### UI の応答を処理完了から分離する

ユーザー操作では、重い処理の完了を待つ前に、操作受付、画面の shell、placeholder、進捗などを表示する。
利用可能な bounded result を先に提示し、必要な詳細へ段階的に更新する。

ユーザーが開始した処理を prefetch、cache warming、off-screen rendering より優先する。
画面や対象が変わった場合は不要な処理をキャンセルし、identity または generation により古い完了結果を破棄する。

この方針は画像、文字起こし、Markdown、検索、calendar などすべての UI workload に適用し、
特定の View、framework、pixel size、cache implementation を ADR の規範にしない。

### queue contract を明示する

非同期境界には次を定める。

- 容量または、unbounded であることを許容する明示的な根拠
- overflow 時に drop、coalesce、reject、fail のどれを行うか
- cancellation と終了の owner
- 正常停止時に drain する範囲
- 最初の失敗をどこへ返すか

preview と cache は意味を保てる場合に限って集約または破棄できる。
音声フレーム、確定文字起こし、確定翻訳、録音 range は UI の都合で破棄しない。
容量不足で recording-critical data を受理できない場合は、録音失敗として表面化する。

### 負荷時の縮退順序

負荷が競合した場合は次の順序で縮退する。

1. 不要な prefetch と off-screen work を中止する。
2. rebuildable UI の更新頻度、表示範囲、品質を下げる。
3. interactive UI は操作受付と進行状態を維持し、完了待ちを明示する。
4. durable work は破棄せず、順序を保って待機させるか、受付不能を明示的なエラーにする。
5. recording-critical lane は UI を待たず、容量超過を無言の欠落にしない。

### 保証範囲を MainActor stall に限定する

現段階では、MainActor または UI が一時停止しても録音保存と確定文字起こしの永続化が進む構造を保証対象とする。
同一プロセス内の actor 分離は、process-wide deadlock、crash、OOM、OS 停止を防がない。

録音 helper process は先行導入せず、process-wide hang の再現、MainActor stall との切り分け、損失事例、
運用上の復旧要件が揃った時点で別 ADR として判断する。

## Consequences

良い影響:

- 軽量な同期処理を不必要に非同期化せず、録音 hot path の実行コストと停止順序を理解しやすくできる。
- UI workload が増えても、durability と latency の分類から一貫した判断ができる。
- ユーザー操作が background work の後ろで待つ priority inversion を設計レビューで検出できる。
- queue の overflow と drain が暗黙にならず、データ欠落とメモリ増加を別々に検証できる。
- UI の体感速度と録音データ保全を独立して計測できる。

トレードオフ:

- workload を機能単位ではなく処理段階ごとに分類する必要がある。
- progressive presentation では、loading、partial、failed、complete の UI state が必要になる場合がある。
- user-initiated work の優先を保証するには、単一直列 worker を分割するか scheduling policy を持たせる場合がある。
- process-wide hang に対しては、引き続き同一プロセスの障害境界しか持たない。

## Alternatives Considered

### 同期 API をすべて actor 経由にする

却下。同期 API には、定数時間の値参照から disk I/O まで異なる処理が含まれる。
API の形だけで actor hop を追加すると、軽量処理まで複雑になり、priority と lifecycle の問題も解決しない。

### UI 以外の処理を一つの global actor へ集約する

却下。MainActor の直接占有は避けられても、interactive work と speculative work が同じ直列待ち行列を共有し、
priority inversion と障害範囲の拡大を招く。

### 遅い View だけを個別に最適化する

却下。現在観測できる画面を改善しても、新しい UI workload が recording-critical または durable lane を待たせる構造を防げない。

### 録音 helper process を直ちに導入する

却下。MainActor stall に対する分離は同一プロセス内で実現でき、現時点では process-wide hang の頻度と原因が確立していない。
IPC、権限、crash recovery、ファイル ownership を追加する前に観測結果を必要とする。
