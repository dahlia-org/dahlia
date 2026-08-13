# 匿名テレメトリ収集ポリシー

## 目的と適用範囲

Dahlia は、主要機能の利用状況と失敗率を把握して品質を改善するため、TelemetryDeck に匿名の利用イベントを、Sentry に匿名化した技術診断を送る。この文書は実装・レビュー・coding agent の正本であり、公開プライバシーポリシーより細かい許可リストを定める。

テレメトリはベストエフォートである。録音、文字起こし、保存、要約、画面操作を待たせてはならず、送信失敗によってユーザー操作を失敗させてはならない。ユーザーの録音・文字起こしデータベースへイベントを保存せず、Dahlia 独自の再送キューも持たない。

## TelemetryDeck へ送信してよいデータ

公式 Swift SDK が自動付与する次の匿名メタデータを許可する。

- インストールごとのハッシュ化された匿名 ID、匿名セッション ID
- イベント種別と受信時刻
- Dahlia のバージョン・ビルド、SDK バージョン、配布・Debug/Test Mode の区分
- OS 名・バージョン、端末モデル、CPU アーキテクチャ、画面情報
- 言語・ロケール・地域・タイムゾーン、レイアウト方向、外観設定
- VoiceOver、太字、コントラストなど OS が公開するアクセシビリティ設定
- event 発生時の月、週、曜日、日、時刻の hour bucket と weekend 区分
- 初回利用日、累計 session 数、累計利用日数、直近 30 日の利用日数。SDK が install 期間中 UserDefaults に保持する統計から算出する
- 直前・平均 session 秒数。SDK が UserDefaults に保持する直近 90 日分の session から算出する

Dahlia が追加できるイベントとパラメータは以下だけとする。文字列値はコードで定義した enum の固定値であり、自由文、識別子、件数、正確な時刻、ファイル名を渡さない。

| Event | Allowed parameters |
| --- | --- |
| `Dahlia.Recording.started`, `.completed`, `.failed` | `transcriptionMode`: `realtime` / `batch`; `audioSources`: 録音開始時の `microphone` / `systemAudio` / `microphoneAndSystemAudio`（terminal でも同値）; `meetingScope`: 最初の録音 session なら `new`、再開なら `continued`; 失敗時のみ `stage`: `start` / `capture` / `stop` / `persistence`; 完了時のみ `floatValue`: 永続化済み録音時間を分単位に四捨五入して 0〜360 に制限した値 |
| `Dahlia.Transcription.started`, `.completed`, `.failed` | `transcriptionMode`: `realtime` / `batch`; 失敗時のみ `stage`: `start` / `persistence` / `transcription` |
| `Dahlia.Summary.started`, `.completed`, `.failed` | `trigger`: `manual` / `automaticAfterBatch`; 失敗時のみ `stage`: `generation` |
| `Dahlia.Export.started`, `.completed`, `.failed` | `destination`: `vault` / `googleDocs` / `localFiles`; `trigger`: `manual` / `summaryGeneration`; 失敗時のみ `stage`: `export` |
| `Dahlia.AIChat.promptSubmitted`, `.liveModeEnabled` | なし。新規の手動 prompt と Live Mode の false→true 遷移だけを数え、retry と live transcript segment は数えない |
| `Dahlia.MCP.ToolCall.completed`, `.failed` | `origin`: `codexChat`; `category`: `meeting` / `project` / `customerIntelligence` / `unknown`; `operation`: `read` / `write` |

アプリ ID は `TELEMETRYDECK_APP_ID` からビルド時に `Info.plist` へ注入する。未設定なら TelemetryDeck を初期化せず、イベントを破棄する。Debug ビルドは必ず TelemetryDeck Test Mode とする。custom user ID は使用しない。固定 default parameter `runtime` は本体の `app` と内蔵 MCP helper の `mcpHelper` だけを許可する。

内蔵 MCP helper は、Dahlia が非公開引数 `--telemetry-origin codexChat` を付けて起動した場合だけ、親 app bundle の同じ App ID で TelemetryDeck を初期化する。通常の MCP 登録 command にはこの引数を含めず、外部 client からの helper 利用は計測しない。MCP tool 名、引数、結果は送らない。同じ App ID の自動 session event には app と helper の両方が含まれるため、本体の DAU と session は必ず `runtime=app` で絞り込む。

## 指標定義

- `App DAU`: `TelemetryDeck.Session.started` の unique user 数を `runtime=app` で集計する。
- `Recording DAU`: `Dahlia.Recording.started` の unique user 数。一般の DAU と同一視しない。
- 新規録音 meeting 数: `Dahlia.Recording.started` のうち `meetingScope=new` の event count。
- 録音 session 数: `Dahlia.Recording.started` の全 event count。meeting 数とは呼ばない。
- 完了録音の平均時間: `Dahlia.Recording.completed.floatValue` の mean。failed recording は含めない。
- AI Chat DAU: `Dahlia.AIChat.promptSubmitted` または `.liveModeEnabled` の unique user 数。
- 内蔵 MCP 利用: terminal tool call の event/user count と、`failed / (completed + failed)`。外部 MCP adoption とは呼ばない。
- workflow 成功率: best-effort の started/terminal 欠測を避けるため、原則 `completed / (completed + failed)` とする。

## Sentry へ送信してよいデータ

Sentry はクラッシュスタック、Dahlia のリリース・ビルド、実装で許可された匿名診断カテゴリと次の短い技術タグだけを扱う。明示的に捕捉する `Error` はその説明文を送らず、`ErrorReportingService` が匿名診断へ置き換える。タグ値は 80 文字以下の英数字と `.`、`-`、`_` のみに制限し、key ごとの許可値もコードで検証する。

| Tag | Allowed values |
| --- | --- |
| `source` | コードで列挙した固定の処理カテゴリ。画面入力、会議名、ファイル名などを使用しない |
| `audioSource` | `microphone` / `mic` / `system` / `unknown` |
| `locale` | OS が公開する locale identifier |
| `candidateScope` | `all` / `selected` |
| `candidateLanguageCount`, `fallbackCount`, `inferenceFailedCount` | 0〜999 の匿名な言語候補・fallback 件数 |
| `failureKind` | `recordingStorage` / `recordingRecovery` / `recordingAudioPermanent` / `transcription` / `transcriptionStalled` / `transcriptionInterrupted` |
| `errorCode` | `BatchSpeechTranscriberError` が定義する固定 diagnostic code |

Sentry の PII、request、user、extra、自動 breadcrumb、network breadcrumb、失敗 HTTP request、performance trace は無効にする。`beforeBreadcrumb` でも許可カテゴリ以外を破棄する。スクリーンショット自体は送らず、既存のスクリーンショット表示診断では固定 bucket のみ許可する。

許可する breadcrumb は次に限定する。

- screenshot grid の backend 固定値、件数 bucket、最小幅 bucket
- automatic screenshot の `fingerprint` / `encoding` / `persistence` stage と 500 / 1000 / 2000 / 5000 ms の duration bucket
- automatic screenshot stream の固定 restart event

## 送信禁止データ

両サービスへ次を送ってはならない。

- 音声、文字起こし、字幕、要約、ノート、チャット、プロンプト、AI 応答の内容または断片
- スクリーンショット、画像データ、OCR 結果
- 会議名、参加者、メールアドレス、カレンダー予定、組織・顧客・Project の名称や内容
- Vault・ファイル・URL の名前またはパス、meeting/session/recording/project/file ID
- API key、token、cookie、認証情報、request/response body、任意のネットワーク URL
- 生のエラーメッセージ、`localizedDescription`、ログ行、任意の自由文
- Dahlia の custom parameter としての正確な時刻・録音秒数、文字数、件数など、上記の SDK 自動項目と許可表にない値
- IP アドレス、位置情報、広告 ID、連絡先、独自 user ID

## 非ブロッキング要件

機能コードは型付き `UsageTelemetryEvent` を `UsageTelemetryService` に渡すだけとする。MCP server は型付き `MCPUsageTelemetryEvent` を注入 reporter に渡す。SDK の `initialize` と `signal` を呼べるのは各 executable の `TelemetryDeckClient` だけである。初期化時の disk cache 読み込みは background task で行い、完了前のイベントは欠測させる。公式 SDK の `signal` は送信を待たず、内部の utility キューと bounded cache に処理を委譲する。

次は禁止する。

- SDK の送信完了を `await`、ポーリング、flush で待つこと
- 独自の HTTP 送信、再送、永続キュー、録音停止 drain への組み込み
- audio callback、音声フレーム、字幕 token、文字起こし segment など高頻度経路からのイベント送信
- イベントごとの `Task`、MainActor 外へ逃がすためだけの GCD、送信失敗の UI 表示

SDK の非ブロッキング契約や cache 上限が将来変わる場合は、依存更新前に再検証し、この文書と ADR を更新する。

## 変更手順

新しいイベント、パラメータ、provider、SDK の自動メタデータを追加・変更する場合は、実装前にこの許可表、公開プライバシーポリシー、テストを更新する。内容データや識別子が必要に見える場合は実装せず、別の集計方法を設計してユーザー承認を得る。

レビューでは、機能コードからの SDK 直接利用がないこと、値が enum に閉じていること、開始と終端が重複しないこと、欠測しても機能が完了することを確認する。テストは fake client/reporter を使い、外部へ送信しない。

## 参考

- [TelemetryDeck Swift Setup](https://telemetrydeck.com/docs/guides/swift-setup/)
- [TelemetryDeck default parameters](https://telemetrydeck.com/docs/ingest/default-parameters/)
- [ADR-0025](adr/0025-adopt-allowlisted-nonblocking-telemetry.md)
- [ADR-0026](adr/0026-measure-product-adoption-with-bounded-telemetry.md)
