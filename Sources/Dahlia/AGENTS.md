# Sources/Dahlia — アプリ実装ガイド

このファイルは `Sources/Dahlia/` 配下に適用する。`Database/` の変更には、さらに `Database/AGENTS.md` を適用する。

## アーキテクチャ上の完了条件

録音経路は次の所有関係を保つ。

```text
AudioCaptureManager (マイク / AVAudioEngine)
SystemAudioCaptureManager (システム音声 / ScreenCaptureKit)
    ↓ onAudioBuffer
AudioSourcePipeline → CapturedAudioChunk (セッション相対時刻付き)
    ↓ AudioFrameRouter
    ├─ BatchAudioFileWriter (欠落禁止)
    └─ AudioBufferBridge → SpeechTranscriberService (低遅延、音源ごとに最大 1 つ)
        ↓ TranscriptionEvent
        ↓ TranscriptionEventPipeline
        ├─ UI lane (preview は音源ごとに最新値へ集約)
        │   ├─ TranscriptStore (リアルタイム状態の正本)
        │   └─ LiveCaptionStore (録音中だけの一時字幕)
        └─ persistence lane (確定・翻訳イベントは欠落禁止)
            ↓ TranscriptPersistenceWriter
            GRDB/SQLite (確定済みセグメントを順序どおり差分保存)
```

- `RecordingSessionController` actor が capture、recognizer、CAF recorder、batch scheduler の実行リソースを所有する。
- `CaptionViewModel` はセッション要求、UI 状態、store へのイベント投影、Meeting persistence を担当し、AVFoundation / Speech の実行リソースを保持しない。
- 認識イベントは `TranscriptionEventPipeline` で UI と永続化へ分岐し、MainActor の描画停滞を確定セグメントの保存へ伝播させない。

## コンポーネントの配置

| レイヤ | 主なコンポーネント |
|--------|--------------------|
| Audio | `AudioCaptureManager`、`SystemAudioCaptureManager`、`AudioSourcePipeline`、`AudioFrameRouter`、`AudioBufferBridge` |
| Speech | `SpeechTranscriberService`、`PreviewTranslationCoordinator` |
| Models / Storage | `TranscriptStore`、`MeetingPersistenceService`、`MeetingRepository`、`AppDatabaseManager` |
| Services | `RecordingSessionController`、`SummaryService`、`VaultSyncService`、Google Calendar / Drive、各種 Export |
| UI | `CaptionViewModel`、`SidebarViewModel`、`ContentView`、`MeetingListSidebarView`、`ControlPanelView`、`SettingsView` |

既存の所有関係に収まらない新しい責務を加える場合は、類似コンポーネントを先に確認し、重複する coordinator、store、repository を作らない。

## 並行処理

- UI に公開する状態、ViewModel、Store、Repository は `@MainActor` に隔離する。
- capture、音声認識、長寿命の可変 runtime は actor で所有し、既存の `RecordingSessionController` の所有境界を迂回しない。
- 新しい `@unchecked Sendable` は原則として導入しない。Apple framework やデリゲート境界で必要な場合は、小さな adapter に閉じ込め、可変状態の隔離根拠をコード上に残す。
- `@preconcurrency import` は Apple framework 側の Sendable 適合不足を吸収する import 境界に限定し、アプリ自身のデータ競合を隠すために使わない。

## 共通実装規約

- 新しいテーブル行・ドメインエンティティの ID は、時系列ソート可能な `UUID.v7()` を使う。
- SwiftFormat / SwiftLint の設定（4 スペース、150 文字行制限、trailing comma）に従う。
- UI 文字列は `Utilities/L10n.swift` に computed property を追加し、`Resources/ja.lproj` と `Resources/en.lproj` の両方へ同じキーを追加する。日本語をプライマリとする。
- 設定画面は `Form` + `.formStyle(.grouped)`、`Section`、`LabeledContent`、標準コントロールを使う。独自カード、独自行、コントロールの固定幅 `frame` は追加しない。トグルは `.toggleStyle(.switch)`、複数選択は `.checkbox` を使う。

## 検証

- 変更したレイヤに対応するテストを先に実行する。録音経路では、開始、停止、再構成、音源別ルーティング、バッチ保存の境界まで確認する。
- UI の変更では Debug ビルドに加え、可能なら対象画面の通常、空、エラー、無効状態を確認する。
