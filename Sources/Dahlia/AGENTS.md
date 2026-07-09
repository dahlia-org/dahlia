# Sources/Dahlia — アーキテクチャと実装規約

## 録音データフロー

```
AudioCaptureManager (マイク / AVAudioEngine)
SystemAudioCaptureManager (システム音声 / ScreenCaptureKit)
    ↓ onAudioBuffer コールバック
AudioBufferBridge → AsyncStream<AnalyzerInput>
    ↓
SpeechTranscriberService (actor、音声ソースごとに 1 つ)
    ↓ results AsyncSequence
TranscriptStore (@MainActor、speakerLabel ごとに 200ms スロットル)
    ↓ Combine .debounce(500ms)
MeetingPersistenceService → GRDB/SQLite (確定済みセグメントを差分 INSERT)
```

音声ソースごとに独立した `(SpeechTranscriberService, AudioBufferBridge)` パイプラインを持ち、`CaptionViewModel.pipelines` が管理する。

## 主要コンポーネント

| レイヤ | コンポーネント |
|--------|----------------|
| **Audio** | `AudioCaptureManager`（マイク）、`SystemAudioCaptureManager`（システム音声）、`AudioBufferBridge` |
| **Speech** | `SpeechTranscriberService`（actor）、`PreviewTranslationCoordinator` |
| **Storage** | `TranscriptStore`、`MeetingPersistenceService`、`MeetingRepository`、`AppDatabaseManager` |
| **LLM** | `LLMService`（OpenAI 互換 API）、`SummaryService`（`SummaryDocument` 構造化出力のマルチモーダル要約） |
| **Services** | `VaultSyncService`（FSEvents）、`MeetingDetectionService`（3 層検出）、`RecordingCoordinator`、`LiveSubtitleOverlayCoordinator`、`KeychainService`、Google Calendar/Drive クライアント、`LiveSubtitleOverlayService`、各種 Export |
| **ViewModels** | `CaptionViewModel`（録音制御・パイプライン管理）、`SidebarViewModel`（GRDB ValueObservation でミーティング一覧と設定補助データを監視） |
| **Views** | `ContentView`（NavigationSplitView）→ `MeetingListSidebarView` + `ControlPanelView` + `SettingsView` + `MenuBarExtra` |

## 並行処理規約

- ViewModel / Store / Repository は `@MainActor`。
- `SpeechTranscriberService` は `actor`。
- `@unchecked Sendable` は ScreenCaptureKit のデリゲートのみに限定する。
- Apple フレームワークの Sendable 警告は `@preconcurrency import` で抑制する。

## UI 規約

- UI 文字列は `Utilities/L10n.swift` に computed property を追加し、`Resources/ja.lproj` と `Resources/en.lproj` 両方の `Localizable.strings` にキーを追加する。
- 設定タブ（`Views/Settings/`）は `Form` + `.formStyle(.grouped)` を使い、見出しは `Section` のヘッダー、説明文は `Section` のフッターまたはラベルの 2 つ目の `Text`（subtitle）で表現する。`LabeledContent` と標準コントロールを使い、カスタムのカード・行コンポーネントやコントロールへの固定幅 `frame` を追加しない。トグルは `.toggleStyle(.switch)`、複数選択リストは `.checkbox` を使う。
