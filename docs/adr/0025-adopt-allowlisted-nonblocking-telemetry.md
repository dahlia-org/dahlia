# ADR-0025: 許可リスト制の匿名テレメトリを非ブロッキングで送る

## Status

Accepted

## Date

2026-08-10

## Context

Dahlia は Sentry でクラッシュと技術エラーを観測しているが、録音、文字起こし、要約、書き出しという主要ワークフローの利用・成功・失敗を内容データなしに把握できなかった。録音アプリであるため、イベント追加の自由度より、会話内容を外へ出さないことと録音・保存を妨げないことを優先する必要がある。

TelemetryDeck の公式 Swift SDK は匿名化された install ID と端末・アプリの既定メタデータを付け、`signal` 後の処理と送信を内部キューへ委譲する。一方、custom parameter は自動匿名化されないため、任意 dictionary を機能コードへ公開すると機密データ混入の境界を守れない。

## Decision

- 公式 TelemetryDeck Swift SDK を導入し、Sentry はクラッシュ・匿名技術診断、TelemetryDeck は低頻度の利用メトリクスに分担する。
- `TELEMETRYDECK_APP_ID` をビルド時に `Info.plist` へ注入する。未設定時は無効、Debug は Test Mode とする。利用者向け opt-out 設定は設けない。
- custom event と parameter は [`docs/telemetry.md`](../telemetry.md) の許可リストと `UsageTelemetryEvent` の enum に閉じる。任意文字列、ID、内容、時間・件数を送らない。
- SDK import と呼び出しは `TelemetryDeckClient` に限定する。cache を同期読込する SDK 初期化は background で行い、完了前のイベントは欠測させる。機能コードは送信完了を待たず、開始・完了・失敗の境界で `UsageTelemetryService.record` を呼ぶ。
- 独自送信、独自再送、永続キューは持たない。SDK の bounded cache からの欠測は許容し、録音・文字起こし・保存・UI の成功を優先する。
- 明示的な Sentry error capture は、生の `Error` 説明を固定カテゴリへ置換し、許可された固定タグだけを残す。
- policy と adapter 境界を AGENTS と lint から辿れるようにし、変更には policy・公開文書・テストの同時更新を求める。

## Consequences

良い影響:

- 会話内容やローカル識別子を送らずに、主要機能の採用状況と失敗箇所を観測できる。
- テレメトリ障害や遅延が録音停止、永続化、UI 操作をブロックしない。
- coding agent と reviewer が許可範囲と変更手順を一箇所から確認できる。

トレードオフ:

- opt-out UI はなく、アプリ ID を設定した配布ビルドでは許可リスト内の匿名イベントを送る。
- duration、件数、会議別 funnel を送らないため詳細分析はできない。
- SDK の既定メタデータと非ブロッキング実装を依存更新ごとに監査する必要がある。
- ベストエフォートのため、終了直前やオフライン時のイベントは欠測し得る。

## References

- policy: [`docs/telemetry.md`](../telemetry.md)
- runtime: `Sources/Dahlia/Services/UsageTelemetryService.swift`
- SDK adapter: `Sources/Dahlia/Services/TelemetryDeckClient.swift`
