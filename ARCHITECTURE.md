# Dahlia Architecture

この文書は、Dahlia の現在のシステム構成、守るべき architecture contract、実装との適合状況、修正完了条件を示す正本である。
設計レビューと修正作業では、ここに記載した target state と現状との差分を基準にする。実装時の必須ルールは各スコープの
`AGENTS.md`、機能を作るかどうかの判断基準は [`PRODUCT.md`](PRODUCT.md)、過去の判断理由は
[ADR index](docs/adr/README.md) を参照する。

- `AGENTS.md`: Codex が最初に読む、短いルーティングと必須ガードレール
- `PRODUCT.md`: 何を作り何を作らないかを決める product tenet と、競合時の優先順位
- `ARCHITECTURE.md`: 現在の構成、横断的な設計原則、未適合箇所、修正の到達条件
- `docs/architecture/`: 特定領域の現在の data flow、runtime scenario、永続化境界
- `docs/adr/`: 決定時点の背景、選択肢、トレードオフを残す履歴

`Reliability Scope` から `Failure and Overload Policy` までは normative な target state である。
`Runtime Data Flow` と `Conformance Status` は現在の実装を記述する。未適合箇所は既成事実として追認せず、保証範囲、
source of truth、再生成可能性、実測値に基づいて target state を再評価するか、`Remediation Plan` に従って減らす。

最終確認日: 2026-08-12

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

音声と文字起こしの mode／ライブ機能の組み合わせ、データごとの永続化境界、開始・停止・異常時の runtime scenario は
[`音声・文字起こしデータフロー`](docs/architecture/audio-transcription-data-flow.md) を正本とする。

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
            ├─ bounded live-caption relay
            │   └─ MainActor → LiveCaptionStore
            │
            ├─ UI lane
            │   ├─ latest preview / bounded reloadable projection
            │   └─ TranscriptStore
            │
            └─ persistence lane
                TranscriptPersistenceWriter
                    ↓
                GRDB / SQLite
```

`RecordingSessionController` actor が capture、recognizer、segmented writer、batch scheduler の runtime resource を所有する。
`CaptionViewModel` はユーザー要求、UI 状態、表示 projection、停止シーケンスの調整を担当し、AVFoundation や Speech の
runtime resource を所有しない。

`TranscriptStore` は再読込可能な bounded UI projection であり、確定文字起こしの正本ではない。
完全な文字起こしを必要とするサマリー、書き出し、外部アクセスは SQLite を MainActor 外で読む。
録音音声は writer queue への受理や partial CAF への書き込みではまだ durable ではなく、検証済みの immutable CAF と
対応する SQLite state が `ready` になった時点で再読込可能な正本となる。

利用テレメトリは録音・永続化の正本から独立した lossy projection である。`CaptionViewModel` などの owner は低頻度の
workflow 境界で型付き `UsageTelemetryEvent` を生成し、`UsageTelemetryService` が公式 SDK の非ブロッキングキューへ渡す。内蔵 MCP helper も型付きの粗い tool-call event だけを専用 adapter へ渡し、外部 MCP client は計測しない。
SDK 初期化時の cache I/O は background で行い、準備完了前のイベントは欠測を許容する。送信完了を待たず、独自の再送・永続キューを持たない。許可データと SDK 境界は
[`匿名テレメトリ収集ポリシー`](docs/telemetry.md) を正本とする。

顧客インテリジェンスは録音クリティカルパス外の、再試行可能な補助永続化である。

```text
Google Calendar / EventKit
    ↓ CalendarEvent.participants
Meeting creation / recording-start coordinator
    ├─ core Meeting transaction
    └─ post-commit CustomerIntelligenceIngestionService (best effort)
       └─ recordings: only after capture starts successfully
            ├─ Vault-scoped Contact
            ├─ Meeting participant
            ├─ domain → one or more root Organizations
            └─ unambiguous, setting-enabled Organization membership

SQLite typed records
    ├─ Organization / unit / domain / membership
    ├─ Contact / Meeting participation
    ├─ Project resource reference
    ├─ Glossary term
    └─ Insight + typed evidence/context reference
            ↓ bounded, Vault-scoped queries (read-only by default; writes only with --write)
        Dahlia MCP
```

Contactのローカルidentityは `UUID + (vaultId, email)` であり、Vault横断またはクラウド全体の人物identityではない。
Organization/Contactなどの正準レコードと、AIまたは人によるInsightを分離する。Insightのreview状態は正準レコードへの
write-backを発生させない。汎用参照は書き込み時にtarget存在とVault一致を検証し、target削除時はtriggerで除去する。
詳細な判断と将来のContact統合条件は
[ADR-0011](docs/adr/0011-vault-scoped-customer-intelligence.md)を正本とする。

任意の Dahlia Server runtime は内蔵 Codex の provider transport を所有し、macOS の録音・文字起こし critical path には入らない。
Better Auth、Gateway 管理 metadata、将来の meeting cloud sync は単一の Drizzle application database を共有する。
`DAHLIA_DATABASE_TYPE` は `sqlite`、`postgres`、`lakebase`、`hyperdrive`、`d1` から選び、SQLite／PostgreSQL の接続先は
`DAHLIA_DATABASE_URL` で指定する。Node は SQLite／PostgreSQL／Lakebase、Workers は D1／Hyperdrive／PostgreSQL を扱う。
Lakebase は公式 `@databricks/lakebase` connector で OAuth credential を更新する。
database 選択は認証および AI backend と独立する。`DAHLIA_AI_BACKEND` で Databricks、Cloudflare、OpenAI を選択し、Databricks は App service principal、その他は `OPENAI_API_KEY` と必要に応じて `OPENAI_BASE_URL` を使う。
Databricks Apps の header identity は sessionless だが、Model Alias と administrator の正本として Lakebase を使用する。Responses request は上限内で検証して upstream model を
変換し、upstream response body は streaming relay する。request と response の content は DB、cache、analytics、application log
へ保存しない。

```text
Dahlia macOS / bundled Codex 0.148.0
    ↓ authenticated OpenAI Responses request
/api/v1
    ├─ Better Auth OAuth access token
    └─ Databricks Apps / trusted proxy identity
        ↓ database-backed Model Alias resolution
    OpenAI-compatible upstream adapter
        ↓ administrator-owned credential
    upstream Responses API

Drizzle application store (SQLite, PostgreSQL, Lakebase, Hyperdrive, or D1)
    ├─ Model Alias + platform administrator
    └─ user + session + OAuth metadata (accounts mode)
```

Cloudflare では Hono Worker は `/api/**`、`/.well-known/**`、`/healthz` だけを処理する。React SPA と静的 asset は
Workers Static Assets が直接配信し、Worker 内から asset binding を呼ばない。`/dashboard/**` の navigation は
`index.html` へ fallback する一方、API と discovery の未定義 path は Hono の 404 を維持する。

Gateway、認証 store、upstream の停止は AI 操作だけを失敗させる。macOS の起動、録音、音声保存、文字起こし、
閲覧、検索はこの runtime を待たず、音声、SQLite、Vault を upload する API は持たない。runtime と data boundary の判断は
[ADR-0043](docs/adr/0043-unify-dahlia-server-application-database.md)を正本とする。

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
| `lossy observability` | 匿名の workflow event、技術診断 | 中核処理を待たせず、内容データを持たず、欠測を許容する |

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
- unbounded queue は、drop した入力を再生成できず、別の durable source of truth もない場合に限って使い、理由と停止時の
  drain を明記する。この例外は process-wide stall や OOM を保証対象へ追加するものではない。
- `Task.detached` を MainActor 回避の一般解として使わず、lifecycle と cancellation を所有する worker を優先する。
- Apple framework の同期 API を `Task {}` で包むだけでは MainActor から離れない場合がある。呼び出し元の isolation を確認する。

realtime-only recognition は、batch 音声という再処理可能な正本を持たないため、`LiveAudioFrameWorker` と
`AudioBufferBridge` の lossless queue を意図的に unbounded とする。batch 音声を保存する mode では live recognition を
rebuildable projection として bounded latest-wins にできる。この選択はモードごとに行い、同じ capture frame を
recording-critical lane から捨てる根拠にはしない。

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

全文検索は `search_documents` registry と contentless `search_documents_fts` を再構築可能な projection として扱う。meeting metadata、構造化 summary の本文、project、全 screenshot の検出文字と画像説明を索引し、summary の metadata・内部識別子と文字起こし・翻訳文は対象にしない。ミーティング自由文検索はアプリと MCP のどちらも title、description、summary、calendar、tags を対象とし、project path は Project 専用検索と明示的な Project 絞り込みだけに使う。画像解析の正本は `screenshots.ocrText` と `screenshots.caption` に保存し、screenshot insert trigger は coalesce 可能な `screenshotAnalysis` job の upsert だけを行う。utility-priority の `SearchIndexer` actor は Codex app-server の `gpt-5.6-luna`、reasoning effort `low` に1枚ずつ最大8並行で送り、正本保存、Lindera tokenization、FTS 更新を一つの複合 job として処理する。指定モデルへフォールバックせず、Codex の未設定、未認証、モデル利用不可では並行処理を停止し、試行回数を消費せず job を queue に残す。Indexer は vector worker と共に録音開始前に停止して録音終了後に再開し、録音中は画像解析を含む projection work を実行しない。screenshot は meeting 検索結果へ統合せず、同じ検索画面と MCP の独立した結果として返す。要約生成には従来どおり画像を渡し、抽出結果を代替入力にしない。初期構築・再構築中は不完全な結果を返さず検索 unavailable とし、索引の遅延や failure は録音、確定文字起こし、正本 metadata と summary の commit を待たせない。

任意導入の Neural 検索は Apple の MLX 実装で EmbeddingGemma 300M 4-bit をローカル実行し、MRL 出力の先頭256次元を再正規化して `search_documents_vec` に保存する。meeting は有効な `SummaryDocument` の description または本文に空白以外の実コンテンツがある場合だけ、meeting title とその summary コンテンツを vector 化する。Meeting description、calendar、tag、project path は meeting vector に含めず、Project vector の類似度もミーティング候補や順位に使わない。project は解決済み path と description を vector 化するが、ミーティング検索からは参照しない。ベクトル検索は既定で無効とし、無効中は vector job を作らず Neural を検索モードに表示しない。有効化だけでは索引を作らず、設定画面で明示的に再構築した場合だけ全件をキューへ追加する。無効化では既存の vector と job を保持し、無効中に索引対象が変化した場合は job を作らず再構築待ちへ戻す。有効時の vector worker は FTS projection の更新を独立に追随し、最大4文書かつ padding 込み4096 tokenまでを1バッチとして直列に推論する。録音中は FTS worker と共に停止する。アプリは filter 適用後に cosine 0.45 未満を除外した vector 上位100件と FTS 上位100件を RRF で統合し、同点では FTS を優先する。configuration hash 不一致を含め、vector が未導入・未構築・失敗中なら FTS の結果を維持する。MCP は MLX をリンクせず、常に FTS を使う。

ミーティングサイドバーは SQLite を正本とし、最新 50 件から keyset pagination で段階表示する。表示用 projection は
最大 500 件に制限し、それ以前は全履歴の FTS projection から検索可能にする。文字列検索は索引 revision 付き relevance
cursor、filter-only 検索は時系列 keyset cursor を使い、新しい検索語で古い処理をキャンセルする。選択詳細とチャット候補は一覧とは別の projection とし、チャット候補は
チャット UI が必要とするまで読み込まない。
複数語の全文検索は FTS vocabulary の文書頻度が最小の token から候補 meeting を作り、残りの token を候補文書内で
検証する。SQLite read は 30 秒でキャンセルし、広すぎる query には絞り込みを求める。検索は WAL 上の専用 read connection を使い、
高頻度語の検索が確定文字起こしの durable write を待たせない。起動時に別プロセスとの競合で WAL へ切り替えられない場合はアプリ起動を優先して primary connection へ縮退し、次回起動で再試行する。

ここでいう上限は、必ずしもユーザーが閲覧する一つの完全な文書を切り詰めることではない。チャット本文のように raw content
自体を完全に残す必要がある場合は、同時に保持する解析世代、待機要求、cache cost、実際に materialize する layout を有界にし、
入力サイズ依存の parse を MainActor 外へ置く。完全な raw content の保持と、再生成可能な projection の負荷制御を混同しない。

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
6. lossy observability は中止または欠測を許容し、他の class の成功条件にしない。

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

2026-07-25 時点の実装を target state と照合した結果を示す。`Partial`、`Gap`、`Unverified` は修正、証明、または target state
自体の再評価が必要である。意図的な unbounded queue や OS-owned stage は根拠と保証範囲を表中に明記し、記載範囲を超えた前例にしない。

| Area | Status | Evidence and deviation |
| --- | --- | --- |
| Capture hot path | Conforms | `AudioSourcePipeline.capture` と `AudioFrameRouter.route` は小さな lock と同期処理で構成され、per-frame task を作らない |
| Immutable audio ingestion | Conforms | `SegmentedAudioSourceWriter.appendBuffer` は bounded queue を使い、overflow を明示的な recording error にする |
| UI／persistence separation | Conforms | `enqueue` は suspension より前に durable ingress を確定する。逐次 recognition producer は MainActor を直接待たず、ライブ字幕は bounded relay への短い actor enqueue 後に独立して配送する |
| Bounded UI projection | Conforms | preview と文字起こしは集約／window 化する。batch mode の一時的なライブ字幕は DB reload で復元できないため、100 event 上限で preview／translation を latest-wins にする専用 relay から `LiveCaptionStore` へ分離する。`LiveCaptionStore` は録音セッション中の履歴を保持する一方、overlay は差分更新を最大 5 Hz で公開し、最新 1〜5 件だけを高さ計測して全履歴の layout を `LazyVStack` で遅延生成する。reloadable な `TranscriptStore` projection だけを bounded UI lane に置く。streaming Markdown は完全な raw 本文を残しつつ、実行中 1 件と置換可能な最新 1 件へ解析要求を集約し、MainActor 外で parse する。会話の scroll 文脈では block layout を lazy 化し、固有サイズが必要な reasoning の開閉領域では eager layout を使う。完了済み cache は件数と byte cost で制限する |
| Realtime recognition backlog | Conforms (documented unbounded) | batch 音声がない realtime mode は再生成不能な入力を落とさない lossless queue、batch mode は bounded latest-wins を使う。長時間の Speech stall による process-wide memory exhaustion は保証対象外 |
| Persistence overload | Gap (measurement-ready) | ingress／retry backlog の event count、text bytes、oldest age、queue／SQLite duration、retry backoff、single-flight write state と high-water を OSLog と test snapshot で取得できるが、queue policy と bounded implementation は未決定 |
| Recording-start MainActor I/O | Conforms | `createNew`／`createAppending` が DB transaction を非同期実行し、MainActor は完了後の store／context 反映だけを行う |
| System-audio runtime isolation | Conforms (app-owned boundary) | manager actor が generation ごとの single-flight stop と callback drain を所有する。delegate adapter の lock は sample admission だけに限定し、停止前に受理済みの callback は routing まで完了させる。concrete `SCStream` の動作は OS integration validation として別に扱う |
| Normal stop drain and failure | Conforms | capture の新規受付を閉じて in-flight callback、recognition、batch writer を drain する。realtime stop が失敗した場合は controller が runtime 参照を保持し、呼び出し側が `abort()` で capture／recognition／batch resource を解放してから state を reset する。capture の最初の失敗は realtime では throw し、batch では有効な録音結果と併せて返して batch 専用の failure state で明示する |
| Async surface | Conforms | `preparedCaptureFormat` は同期化し、未使用の非同期 no-op `endActiveRanges` は削除した |
| Screenshot interactive scheduling | Conforms | overlay shell と既存 thumbnail を先に表示し、cacheable decode と非 cache の interactive decode を別 worker lane に分離する。同一 thumbnail miss は集約し、内容変更／削除は stale cache と in-flight completion を無効化し、cancel 済み waiter は直ちに外す |
| UI-lane isolation proof | Conforms | 停止した UI sink の解放前に audio acceptance と finalized persistence が進み、解放後に UI が追いつくことを回帰テストで検証する |
| Process-wide isolation | Out of scope | helper process は導入せず、process-wide hang の証拠が得られた場合に別 ADR で判断する |

## Remediation Plan

修正は次の順序で行う。すべてを一度に refactor せず、各項目を独立した変更として受け入れ条件まで検証する。

### R1: Durable ingress を observer より先に確定する

実施状況: Completed (2026-07-24)

`TranscriptionEventPipeline.enqueue` では、acceptance check と durable event の persistence ingress の間に `await` を置かない。
UI projection と optional observer はその後に処理する。逐次 producer が後続 event を生成できるよう、MainActor や外部 I/O を
observer callback 内で直接待たない。observer が独自に backlog を持つ場合は rebuildable lane として容量と集約規則を定め、
callback はその lane への短い enqueue だけを行う。

完了条件:

- block した observer を解放する前に finalized event が persistence sink へ到達する。
- observer の停止中も、後続の finalized event と translation event の順序が persistence lane で維持される。
- MainActor の同期停止中も逐次 recognition producer が後続 finalized event を durable ingress へ渡せる。
- `finish()` と同時に `enqueue` が再開しても、close 済み stream へ受理済み扱いで書き込まない。

### R2: 録音開始時の同期 DB transaction を MainActor から外す

実施状況: Completed (2026-07-24)

`MeetingPersistenceService` の initializer から DB read／write を除き、MainActor 外の async factory または既存 repository 境界で
meeting、recording session、継承 project を一つの transaction として準備する。MainActor は返された値を UI state へ反映する。
DB transaction 自体は非同期化する正当な理由があるが、結果の値変換や store 更新まで別 actor に移さない。

完了条件:

- `@MainActor` initializer と同期 UI callback から `DatabaseQueue.read/write` が呼ばれない。
- DB を意図的に遅延させても操作受付後の MainActor が応答し、録音 runtime は transaction 成功前に部分開始しない。
- 新規 meeting、追記、開始失敗 rollback の既存 transaction 境界とデータを維持する。

### R3: MainActor stall に対する保証を同期的に検証する

実施状況: Completed (2026-07-24)

有限時間 MainActor を同期的に占有する test harness を追加し、その間に別 executor から audio ingestion と finalized event を進める。
async gate だけを使った既存テストは残し、異なる failure mode として扱う。

完了条件:

- MainActor 解放前に audio writer の accepted frame count と persistence probe の進行を観測できる。
- MainActor 復帰後に UI projection が再読込または集約済み状態へ追いつく。
- test は timeout を持ち、失敗時にも MainActor と worker を必ず解放する。

### R4: 正当な suspension がない async API を同期化する

実施状況: Completed (2026-07-24)

`preparedCaptureFormat` は同期関数へ戻す。未使用の `endActiveRanges` は、protocol requirement でなければ削除し、
必要なら実際の lifecycle operation を表す名前と契約に置き換える。機械的に周辺 API まで同期化せず、各 `await` の理由を確認する。

完了条件:

- 変更対象に `await`、isolation crossing、非同期 cleanup がないことを call site と test で確認する。
- recording start、reconfiguration、finish の順序が変わらない。

### R5: Persistence backlog の上限と failure mode を決める

実施状況: Instrumentation completed (2026-07-24)。queue policy の決定と bounded implementation は Pending。

pipeline ingress と writer retry backlog について、event count、UTF-8 text bytes、oldest age、high-water、
queue wait、sink／SQLite duration、失敗回数、retry backoff、write in-progress／waiter count を
content／identifier なしで OSLog と test snapshot へ記録する。writer の DB transaction は single-flight とし、
書き込み中に受理した event は同じ owner が続けて drain する。
SQLite stall の実測結果を得るまでは `.unbounded` と retry 保持の動作を変更しない。

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

実施状況: Completed for the app-owned `SystemAudioCaptureManager` lifecycle (2026-07-24)。
署名済み debug build／launch smoke も同日に完了した。実 `SCStream` の start／stop を伴う手動 integration scenario は未実施であり、
app-owned lifecycle の完了状況とは分けて扱う。

Apple delegate callback を受ける adapter と、可変 capture state の owner を分離する。`@unchecked Sendable` が必要な場合は
最小の adapter に限定し、各 mutable property が actor、serial queue、lock のどれで保護されるかを型またはコード上で一意にする。
同じ generation の重複 stop は一つの framework operation を共有し、停止完了は serial audio callback queue の drain 後にだけ返す。
format／converter はその serial queue に閉じ込め、lock は sample admission の短い更新と参照だけに使う。

完了条件:

- `SystemAudioCaptureManager` の start、callback、stop が同じ state をどの executor から変更するか説明できる。
- strict concurrency を抑制する範囲が拡大せず、start／stop／unexpected stop の race test を維持する。

ScreenCaptureKit の concrete stream 自体を fake 化するためだけの abstraction は追加しない。抽出した lifecycle state、
sample admission、serial callback drain を決定的に検証する。実 `SCStream` の start／stop は自動 test の完了条件と混同せず、
framework wiring を変更した場合の署名済み debug app による手動 integration scenario として扱う。

### R7: Interactive UI と speculative work の競合を計測して解消する

実施状況: Completed for app-owned screenshot enlargement stages (2026-07-24)

スクリーンショット一覧の cacheable decode と拡大表示の interactive decode は別 worker lane を使う。
クリック時は collection item が保持する thumbnail を overlay へ渡して shell と同時に表示し、詳細 decode 完了後に置き換える。
拡大画像は共有 cache を読み書きせず、閉じると解放し、再度開いた場合は再 decode する。操作から overlay 表示、
worker queue wait、decode、適用までを content／identifier なしで OSLog に記録する。cacheable lane の同一 key miss は
single-flight に集約し、削除中の decode 完了は cache へ再挿入しない。

操作受付、SwiftUI overlay の挿入、worker queue wait、実処理、MainActor への画像適用を別々に計測する。
SwiftUI から compositor の最初の frame presentation を正確には観測できないため、app log の「overlay 表示」「画像適用」を
compositor paint と呼ばない。pixel presentation が必要な性能検証では Instruments など外部 trace を使う。
user-initiated request が共有直列 worker の
background backlog 後方で待つことが確認された場合、cache ownership は共有したまま admission lane を分離するか、
不要な speculative work をキャンセルする。すべての UI 処理へ新しい scheduler を導入しない。

完了条件:

- background workload 中でも、操作受付と画面 shell の表示が重い処理の完了を待たない。
- user-initiated work が開始済みの bounded unit を超えて speculative backlog の後ろへ滞留しない。
- cancellation、cache cost、stale-result rejection の既存保証を維持する。

R1〜R4 と R6 は完了した。R7 は報告されたスクリーンショット拡大経路について app-owned stage の計測点を追加し、
lane を分離した。R5 は instrumentation のみ完了しており、backpressure／disk-backed recovery／明示的 failure の選択は
実測後に別変更として行う。

## Decision Records

意思決定の一覧と読み方は [ADR index](docs/adr/README.md) を参照する。録音と UI 応答性に直接関係する記録:

- [ADR-0002: 録音クリティカルパスを MainActor から分離する](docs/adr/0002-isolate-recording-critical-path-from-main-actor.md)
- [ADR-0004: 録音データを分割された不変セグメントとして保全する](docs/adr/0004-protect-recordings-with-segmented-immutable-storage.md)
- [ADR-0006: 大量文字起こしを bounded projection と keyset pagination で表示する](docs/adr/0006-bounded-transcript-projection.md)
- [ADR-0009: 実行コンテキストと負荷縮退順序を定める](docs/adr/0009-execution-context-and-degradation-order.md)
