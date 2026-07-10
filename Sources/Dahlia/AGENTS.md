# Sources/Dahlia — アーキテクチャと実装規約

## 録音データフロー

```
AudioCaptureManager (マイク / AVAudioEngine)
SystemAudioCaptureManager (システム音声 / ScreenCaptureKit)
    ↓ onAudioBuffer コールバック
AudioSourcePipeline → CapturedAudioChunk (セッション相対時刻付き)
    ↓ AudioFrameRouter (音源ごとに物理capture 1回)
    ├─ BatchAudioFileWriter (欠落禁止)
    └─ AudioBufferBridge → SpeechTranscriberService (低遅延、音源ごとに最大1つ)
        ↓ TranscriptionEvent
        ├─ TranscriptStore (realtimeの正本)
        └─ LiveCaptionStore (録音中だけの一時字幕)
    ↓ Combine .debounce(500ms)
MeetingPersistenceService → GRDB/SQLite (確定済みセグメントを差分 INSERT)
```

`RecordingSessionController` actor が capture、recognizer、CAF recorder、batch scheduler を所有する。`CaptionViewModel` はセッション要求、UI状態、storeへのイベント投影、Meeting persistenceを担当し、AVFoundation/Speechの実行リソースを保持しない。

## 主要コンポーネント

| レイヤ | コンポーネント |
|--------|----------------|
| **Audio** | `AudioCaptureManager`（マイク）、`SystemAudioCaptureManager`（システム音声）、`AudioSourcePipeline`、`AudioFrameRouter`、`AudioBufferBridge` |
| **Speech** | `SpeechTranscriberService`（actor）、`PreviewTranslationCoordinator` |
| **Storage** | `TranscriptStore`、`MeetingPersistenceService`、`MeetingRepository`、`AppDatabaseManager` |
| **LLM** | `LLMService`（OpenAI 互換 API）、`SummaryService`（`SummaryDocument` 構造化出力のマルチモーダル要約） |
| **Services** | `RecordingSessionController`（録音runtime）、`VaultSyncService`（FSEvents）、`MeetingDetectionService`（3 層検出）、`RecordingCoordinator`、`LiveSubtitleOverlayCoordinator`、`KeychainService`、Google Calendar/Drive クライアント、各種 Export |
| **ViewModels** | `CaptionViewModel`（UI・Meeting状態・store投影）、`SidebarViewModel`（GRDB ValueObservation でミーティング一覧と設定補助データを監視） |
| **Views** | `ContentView`（NavigationSplitView）→ `MeetingListSidebarView` + `ControlPanelView` + `SettingsView` + `MenuBarExtra` |

## 並行処理規約

- ViewModel / Store / Repository は `@MainActor`。
- `RecordingSessionController` / `SpeechTranscriberService` / capture adapter は `actor`。
- `@unchecked Sendable` は ScreenCaptureKit のデリゲートのみに限定する。
- Apple フレームワークの Sendable 警告は `@preconcurrency import` で抑制する。

## UI 規約

- UI 文字列は `Utilities/L10n.swift` に computed property を追加し、`Resources/ja.lproj` と `Resources/en.lproj` 両方の `Localizable.strings` にキーを追加する。
- 設定タブ（`Views/Settings/`）は `Form` + `.formStyle(.grouped)` を使い、見出しは `Section` のヘッダー、説明文は `Section` のフッターまたはラベルの 2 つ目の `Text`（subtitle）で表現する。`LabeledContent` と標準コントロールを使い、カスタムのカード・行コンポーネントやコントロールへの固定幅 `frame` を追加しない。トグルは `.toggleStyle(.switch)`、複数選択リストは `.checkbox` を使う。
