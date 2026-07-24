# Dahlia Architecture

この文書は、Dahlia の現在のシステム構成、守るべき architecture contract、実装との適合状況、修正完了条件を示す正本である。
設計レビューと修正作業では、ここに記載した target state と現状との差分を基準にする。実装時の必須ルールは各スコープの
`AGENTS.md`、過去の判断理由は [ADR index](docs/adr/README.md) を参照する。

- `AGENTS.md`: Codex が最初に読む、短いルーティングと必須ガードレール
- `ARCHITECTURE.md`: 現在の構成、横断的な設計原則、未適合箇所、修正の到達条件
- `docs/adr/`: 決定時点の背景、選択肢、トレードオフを残す履歴

`Reliability Scope` から `Failure and Overload Policy` までは normative な target state である。
`Runtime Data Flow` と `Conformance Status` は現在の実装を記述する。未適合箇所は既成事実として追認せず、
`Remediation Plan` に従って減らす。

最終確認日: 2026-07-24

## Reliability Scope

Dahlia が優先して防ぐ障害は、録音中の MainActor または UI の一時停止によって音声や確定文字起こしを失うことである。
UI の応答性と録音データの保全は別の品質軸として扱う。操作が遅く感じられても durable data が保全される場合があり、
反対に UI が応答していても永続化が遅延する場合があるため、両者を独立に検証する。

設計上の保証対象は次のとおり。

- MainActor が一時停止しても、すでに受理した音声フレームの保存処理は UI の完了を待たない。
- 確定文字起こしと確定翻訳の永続化は、再生成可能な UI projection の処理を待たない。
- 音声保存キューの overflow や永続化失敗を、成功または無言の欠落として扱わない。
- 正常な停止処理は capture、recognition、event pipeline、永続化を順に drain する。

次の障害は現時点の保証対象外である。

- プロセス全体の deadlock、crash、強制終了、メモリ枯渇
- OS、音声デバイス、ストレージ自体の停止または故障
- ディスク容量不足など、データを物理的に保存できない状態

録音専用 helper process は、process-wide hang の再現または計測結果によって必要性が示された段階で検討する。
単に actor や `Task` を追加しても、同一プロセスの CPU、メモリ、GPU、ファイル記述子は分離されない。

## Runtime Data Flow

```text
MicrophoneAudioCaptureSession / SystemAudioCaptureManager
    ↓ capture callback
AudioSourcePipeline
    ├─ session-relative timestamp assignment (synchronous, lock-bounded)
    ↓
AudioFrameRouter
    ├─ recording-critical lane
    │   SegmentedAudioSourceWriter.appendBuffer
    │       ↓ bounded queue; overflow becomes an explicit recording error
    │   immutable audio segments
    │
    └─ live-recognition lane
        LiveAudioFrameWorker
            ↓
        AudioBufferBridge → SpeechTranscriberService
            ↓ TranscriptionEvent
        TranscriptionEventPipeline
            ├─ UI lane
            │   ├─ latest preview / bounded reloadable projection
            │   ├─ TranscriptStore
            │   └─ LiveCaptionStore
            │
            └─ persistence lane
                TranscriptPersistenceWriter
                    ↓
                GRDB / SQLite
```

| Boundary | Primary owner | Responsibility |
| --- | --- | --- |
| Physical capture | `MicrophoneAudioCaptureSession`, `SystemAudioCaptureManager` | OS capture lifecycle and raw buffers |
| Per-source routing | `AudioSourcePipeline`, `AudioFrameRouter` | Timestamp assignment and fan-out without per-frame task creation |
| Recording runtime | `RecordingSessionController`, `SegmentedAudioSourceWriter` | Resource ownership, bounded ingestion, immutable segment lifecycle |
| Recognition | `LiveAudioFrameWorker`, `AudioBufferBridge`, `SpeechTranscriberService` | Capture-independent conversion and transcription |
| Event distribution | `TranscriptionEventPipeline` | Separate UI projection and durable persistence lanes |
| UI projection | `CaptionViewModel`, `TranscriptStore`, `LiveCaptionStore` | User requests and bounded, reloadable presentation state |
| Durable transcript | `TranscriptPersistenceWriter`, GRDB/SQLite | Ordered persistence and complete transcript source of truth |

`RecordingSessionController` actor が capture、recognizer、segmented writer、batch scheduler の runtime resource を所有する。
`CaptionViewModel` はユーザー要求、UI 状態、表示 projection、停止シーケンスの調整を担当し、AVFoundation や Speech の
runtime resource を所有しない。

`TranscriptStore` は再読込可能な bounded UI projection であり、確定文字起こしの正本ではない。
完全な文字起こしを必要とするサマリー、書き出し、外部アクセスは SQLite を MainActor 外で読む。

## Workload Classes

機能全体ではなく、処理の各段階を durability、latency、overload behavior によって分類する。
同じユーザー操作でも、ボタンの状態更新は interactive UI、DB commit は durable work、
補助画像の prefetch は rebuildable UI になり得る。

| Class | Examples | Required behavior |
| --- | --- | --- |
| `recording-critical` | capture callback、timestamp 付与、audio routing、writer への受け渡し | 短時間・有界・non-suspending。MainActor を待たず、欠落を隠さない |
| `durable` | immutable audio segment、確定文字起こし、確定翻訳、ユーザーが確定した保存操作 | 順序と完了を追跡し、停止時に drain する。失敗は呼び出し元へ返す |
| `interactive UI` | 選択、画面遷移、開閉、操作開始のフィードバック | 重い処理を待つ前に応答し、投機的処理より優先する |
| `rebuildable UI` | preview、表示 window、画像・Markdown cache、prefetch | 有界、キャンセル可能、集約または再生成可能にする |

durable work を開始する UI は、操作を受理したことと保存が完了したことを区別して表示する。
先に UI を更新する場合でも、永続化失敗を成功として隠さない。

## Execution Context Rules

同期 API か非同期 API かではなく、処理時間、入力サイズ、待機可能性、状態所有権から実行場所を決める。

| Work | Default |
| --- | --- |
| 小さく上限が明確な値変換、状態参照、UI 状態変更 | 同期処理のまま保つ |
| capture callback 内の timestamp 付与と routing | lock 範囲を小さくした同期処理。`await` や callback ごとの `Task` を入れない |
| DB、disk、network、同期 OS query、画像・文書解析など入力サイズ依存の処理 | MainActor 外の所有された service／worker で実行する |
| 長寿命な可変 runtime と順序保証 | actor または明示的に同期された owner に閉じ込める |
| 高頻度イベントから UI への通知 | batch、window、latest-wins など、意味に合う粗い境界で hop する |

追加のルール:

- `async` は実際の suspension、isolation crossing、非同期 lifecycle がある場合に使う。将来重くなる可能性だけで追加しない。
- actor は状態の直列化境界であり、専用 thread や priority queue ではない。優先度の異なる処理を一つの actor に無差別に集約しない。
- lock 内では I/O、外部 callback、unbounded allocation、`await` を行わない。
- queue と stream は、容量、overflow 時の意味、終了方法、drain 方法を所有者の契約として定める。
- `Task.detached` を MainActor 回避の一般解として使わず、lifecycle と cancellation を所有する worker を優先する。
- Apple framework の同期 API を `Task {}` で包むだけでは MainActor から離れない場合がある。呼び出し元の isolation を確認する。

## UI and Interaction Responsiveness

このセクションは、特定の View やメディア形式ではなく、Dahlia の UI/UX 全体に適用する。

### Immediate acknowledgement

ユーザー操作では、重い処理の完了前に操作が受理されたことを示す。選択状態、遷移先の shell、placeholder、進捗、disabled state
などを先に提示し、処理中なのか入力が無視されたのかを区別できるようにする。

### Progressive presentation

利用可能な bounded result を先に表示し、必要な場合だけ詳細または高品質な結果へ更新する。初期表示に必要な範囲を超えて、
全データの読込、decode、layout、parse が終わるまで待たない。

### User intent before speculation

ユーザーが開始した処理は、prefetch、cache warming、off-screen rendering、一覧の先読みより優先する。
対話的処理と投機的処理を同じ直列待ち行列に置く場合は、priority inversion が起きないことを明示的に保証する。

### Bounded and replaceable projections

表示専用データは windowing、pagination、coalescing、byte cost など、データ特性に合う上限を持たせる。
画面や選択対象が変わった場合は不要な処理をキャンセルし、identity または generation を確認して古い完了結果を捨てる。
UI projection を破棄しても、durable source of truth は変更しない。

### MainActor budget

MainActor では、表示状態の反映と短い計算だけを行う。同期 API であっても I/O や入力サイズ依存の処理は MainActor 外へ置く。
一方、単純な値変換まで非同期化して actor hop と task scheduling を増やさない。

次は適用例であり、個別の実装方式や定数を規範にはしない。

| Situation | Application of the policy |
| --- | --- |
| メディアの詳細表示 | 画面の shell と利用可能な preview を先に示し、表示サイズに必要な詳細を後から更新する |
| 長い文字起こし | 全件を常時 layout せず、SQLite を正本とした bounded window を表示する |
| streaming Markdown | 更新ごとの全文再解析を避け、表示 projection を集約・制限する |
| 検索、calendar refresh、候補取得 | 新しい要求で古い結果を無効化し、完了まで UI 操作を占有しない |

## Failure and Overload Policy

負荷が競合した場合は、次の順序で縮退する。

1. 未開始または不要になった prefetch と off-screen work を中止する。
2. rebuildable UI の更新頻度、表示範囲、品質を下げる。
3. interactive UI は操作受付と進行状態を維持し、完了を待つ必要があることを明示する。
4. durable work は破棄せず、所有された queue で順序を保つか、受付不能を明示的なエラーにする。
5. recording-critical lane は UI を待たず、容量超過を録音失敗として表面化する。

preview や cache は意味を保てる範囲で集約・破棄できる。音声フレーム、確定文字起こし、確定翻訳、録音 range は
UI の都合で破棄しない。正常停止では、capture を止めた後に in-flight routing、recognition、event pipeline、
persistence の順で完了を待つ。

観測では少なくとも次を分離する。

- 操作受付から最初の UI feedback まで
- MainActor stall
- background work の待ち時間と実行時間
- audio queue overflow と保存失敗
- finalized event の enqueue から SQLite commit まで
- 正常停止時の各 drain 時間

## Validation Scenarios

設計変更では、影響する workload class に応じて次のシナリオを選んで検証する。

- MainActor を同期的に占有しても、受理済み音声の segment 保存と確定イベントの persistence が進む。
- rebuildable background work が実行中でも、ユーザー操作への最初の UI feedback がその完了を待たない。
- 画面または対象を変更した後、古い非同期結果が現在の UI を上書きしない。
- 入力を queue の想定容量まで増やしたとき、preview は規則どおり集約され、durable data は欠落しない。
- 正常停止時に、各 owner が新規受付を止めてから in-flight work を drain し、最初の失敗を返す。

process-wide hang、crash、OOM の注入は現在の受け入れ条件には含めず、保証範囲を拡張する ADR で追加する。

## Conformance Status

2026-07-24 時点の実装を target state と照合した結果を示す。`Partial`、`Gap`、`Unverified` は修正または証明が必要であり、
現在の実装を新しい設計判断の前例にしてはならない。

| Area | Status | Evidence and deviation |
| --- | --- | --- |
| Capture hot path | Conforms | `AudioSourcePipeline.capture` と `AudioFrameRouter.route` は小さな lock と同期処理で構成され、per-frame task を作らない |
| Immutable audio ingestion | Conforms | `SegmentedAudioSourceWriter.appendBuffer` は bounded queue を使い、overflow を明示的な recording error にする |
| UI／persistence separation | Partial | worker は分離済みだが、`enqueue` は durable ingress より前に optional `eventObserver` を `await` する |
| Bounded UI projection | Conforms | preview は集約され、文字起こしと streaming Markdown は reload 可能な bounded projection を使う |
| Persistence overload | Gap | persistence `AsyncStream` と retry 中の `pendingEvents` に memory bound がない |
| MainActor I/O | Gap | `MeetingPersistenceService` の `@MainActor` initializer が同期 `DatabaseQueue.write` を実行する |
| Runtime isolation | Partial | `RecordingSessionController` の ownership は明確だが、`SystemAudioCaptureManager` などの広い `@unchecked Sendable` が残る |
| Async surface | Partial | suspension のない `preparedCaptureFormat` と非同期 no-op の `endActiveRanges` が API を不必要に非同期化している |
| Interactive UI scheduling | Partial | rebuildable UI の共有直列 worker には user-initiated work を background work より優先する契約がない |
| MainActor-stall proof | Unverified | 現在の pipeline test は async suspension を主に模擬し、MainActor の同期的な占有を end-to-end で検証していない |
| Process-wide isolation | Out of scope | helper process は導入せず、process-wide hang の証拠が得られた場合に別 ADR で判断する |

## Remediation Plan

修正は次の順序で行う。すべてを一度に refactor せず、各項目を独立した変更として受け入れ条件まで検証する。

### R1: Durable ingress を observer より先に確定する

`TranscriptionEventPipeline.enqueue` では、acceptance check と durable event の persistence ingress の間に `await` を置かない。
UI projection と optional observer はその後に処理し、observer の停止、cancellation、reentrancy が durable acceptance を変更しないようにする。
observer が独自に backlog を持つ場合は rebuildable lane として容量と集約規則を定める。

完了条件:

- block した observer を解放する前に finalized event が persistence sink へ到達する。
- observer の停止中も、後続の finalized event と translation event の順序が persistence lane で維持される。
- `finish()` と同時に `enqueue` が再開しても、close 済み stream へ受理済み扱いで書き込まない。

### R2: 録音開始時の同期 DB transaction を MainActor から外す

`MeetingPersistenceService` の initializer から DB read／write を除き、MainActor 外の async factory または既存 repository 境界で
meeting、recording session、継承 project を一つの transaction として準備する。MainActor は返された値を UI state へ反映する。
DB transaction 自体は非同期化する正当な理由があるが、結果の値変換や store 更新まで別 actor に移さない。

完了条件:

- `@MainActor` initializer と同期 UI callback から `DatabaseQueue.read/write` が呼ばれない。
- DB を意図的に遅延させても操作受付後の MainActor が応答し、録音 runtime は transaction 成功前に部分開始しない。
- 新規 meeting、追記、開始失敗 rollback の既存 transaction 境界とデータを維持する。

### R3: MainActor stall に対する保証を同期的に検証する

有限時間 MainActor を同期的に占有する test harness を追加し、その間に別 executor から audio ingestion と finalized event を進める。
async gate だけを使った既存テストは残し、異なる failure mode として扱う。

完了条件:

- MainActor 解放前に audio writer の accepted frame count と persistence probe の進行を観測できる。
- MainActor 復帰後に UI projection が再読込または集約済み状態へ追いつく。
- test は timeout を持ち、失敗時にも MainActor と worker を必ず解放する。

### R4: 正当な suspension がない async API を同期化する

`preparedCaptureFormat` は同期関数へ戻す。未使用の `endActiveRanges` は、protocol requirement でなければ削除し、
必要なら実際の lifecycle operation を表す名前と契約に置き換える。機械的に周辺 API まで同期化せず、各 `await` の理由を確認する。

完了条件:

- 変更対象に `await`、isolation crossing、非同期 cleanup がないことを call site と test で確認する。
- recording start、reconfiguration、finish の順序が変わらない。

### R5: Persistence backlog の上限と failure mode を決める

durable event を drop する `AsyncStream.bufferingNewest/Oldest` への単純置換は行わない。まず event count、text bytes、
SQLite stall duration、retry backlog を計測する。その結果から、audio writer と独立した bounded backpressure または
disk-backed recovery のどちらを使うかを決める。選択した容量、受付不能時の UX、停止時の drain を ADR 0009 の queue contract
として実装前に確定する。

完了条件:

- SQLite を長時間停止させても process memory が無制限に増えない。
- finalized event を無言で drop せず、backpressure、recovery、明示的 failure のいずれかで追跡できる。
- persistence stall が immutable audio ingestion を待たせない。

この項目だけは計測前に queue implementation を決めない。病的ケースのために複雑な spool を先行導入しない。

### R6: `@unchecked Sendable` の ownership を狭める

Apple delegate callback を受ける adapter と、可変 capture state の owner を分離する。`@unchecked Sendable` が必要な場合は
最小の adapter に限定し、各 mutable property が actor、serial queue、lock のどれで保護されるかを型またはコード上で一意にする。

完了条件:

- `SystemAudioCaptureManager` の start、callback、stop が同じ state をどの executor から変更するか説明できる。
- strict concurrency を抑制する範囲が拡大せず、start／stop／unexpected stop の race test を維持する。

### R7: Interactive UI と speculative work の競合を計測して解消する

操作受付、worker queue wait、実処理、最初の描画を別々に計測する。user-initiated request が共有直列 worker の
background backlog 後方で待つことが確認された場合、cache ownership は共有したまま admission lane を分離するか、
不要な speculative work をキャンセルする。すべての UI 処理へ新しい scheduler を導入しない。

完了条件:

- background workload 中でも、操作受付と画面 shell の表示が重い処理の完了を待たない。
- user-initiated work が開始済みの bounded unit を超えて speculative backlog の後ろへ滞留しない。
- cancellation、cache cost、stale-result rejection の既存保証を維持する。

R1〜R3 を信頼性境界の修正と証明として先に行い、R4 と R6 で concurrency surface を簡素化する。
R5 と R7 は計測結果を得てから実装方式を選ぶ。

## Decision Records

意思決定の一覧と読み方は [ADR index](docs/adr/README.md) を参照する。録音と UI 応答性に直接関係する記録:

- [ADR-0002: 録音クリティカルパスを MainActor から分離する](docs/adr/0002-isolate-recording-critical-path-from-main-actor.md)
- [ADR-0004: 録音データを分割された不変セグメントとして保全する](docs/adr/0004-protect-recordings-with-segmented-immutable-storage.md)
- [ADR-0006: 大量文字起こしを bounded projection と keyset pagination で表示する](docs/adr/0006-bounded-transcript-projection.md)
- [ADR-0009: 実行コンテキストと負荷縮退順序を定める](docs/adr/0009-execution-context-and-degradation-order.md)
