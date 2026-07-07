# CLAUDE.md

**Dahlia** — macOS ネイティブのリアルタイム文字起こしアプリ。マイク（AVAudioEngine）とシステム音声（ScreenCaptureKit）を同時にキャプチャし、Apple Speech framework（`SpeechAnalyzer` / `SpeechTranscriber`）で文字起こしし、任意で LLM による要約を生成する。

## スタック

- Swift 6.2 / SwiftUI / macOS 26+
- Swift Package Manager のみ（Xcode プロジェクトは存在しない。生成もしない）
- 外部依存は 2 つだけ: GRDB.swift（SQLite ORM）、sentry-cocoa（クラッシュレポート）

## コマンド

```bash
swift build                                # ビルド
swift run                                  # Debug 実行（未署名、レガシー Keychain フォールバック）
./scripts/run-dev.sh                       # Debug + codesign 実行（Data Protection Keychain + Touch ID）← 開発時推奨
./scripts/build-app.sh && open Dahlia.app  # Release .app バンドル
swift test                                 # 全テスト実行
swift test --filter <TypeName>             # テストスイート単位で実行
./scripts/lint.sh                          # SwiftFormat + SwiftLint（brew install swiftformat swiftlint）
```

> `swift run` は未署名のため Data Protection Keychain を使えない。フル機能の動作確認は `run-dev.sh` を使う。
> pre-commit フック（`scripts/pre-commit`）がステージ済み `.swift` を SwiftFormat で整形する。

## ディレクトリ構成

| パス | 役割 |
|------|------|
| `Sources/Dahlia/` | アプリ本体。アーキテクチャと実装規約は `Sources/Dahlia/CLAUDE.md` |
| `Sources/Dahlia/Audio/` | マイク・システム音声キャプチャ（AVAudioEngine / ScreenCaptureKit） |
| `Sources/Dahlia/Speech/` | 音声認識（`SpeechTranscriberService`）・プレビュー翻訳 |
| `Sources/Dahlia/Database/` | GRDB スキーマ・マイグレーション・Record/Repository。規約は `Sources/Dahlia/Database/CLAUDE.md` |
| `Sources/Dahlia/Services/` | LLM 要約、Google Calendar/Drive 連携、Vault 同期、Keychain、録音/字幕 coordinator、各種エクスポート |
| `Sources/Dahlia/Models/` | ドメインモデル・アプリ設定・`TranscriptStore` |
| `Sources/Dahlia/ViewModels/` | `CaptionViewModel`（録音制御）、`SidebarViewModel`（ミーティング一覧・設定補助データ） |
| `Sources/Dahlia/Views/` | SwiftUI ビュー（ルートは `ContentView` = NavigationSplitView、サイドバーはミーティング一覧） |
| `Sources/Dahlia/Utilities/` | `L10n`、UUID v7、変換ヘルパー |
| `Sources/Dahlia/Resources/` | Assets、`ja.lproj` / `en.lproj` の Localizable.strings |
| `Tests/DahliaTests/` | ユニットテスト。規約は `Tests/DahliaTests/CLAUDE.md` |
| `scripts/` | ビルド・署名・notarize・lint・pre-commit スクリプト |

## 絶対に破ってはいけないルール

1. **DB マイグレーションで既存ユーザーデータを壊さない。** `eraseDatabaseOnSchemaChange` のような破壊的リセットは禁止。登録済みマイグレーションは変更せず、新しいマイグレーションを追加する（詳細: `Sources/Dahlia/Database/CLAUDE.md`）。
2. **新規の外部依存を追加しない。** GRDB.swift と sentry-cocoa 以外の依存が必要になったら、追加せずまずユーザーに相談する。
3. **UI 文字列をハードコードしない。** 必ず `L10n` 経由で参照し、`ja.lproj` / `en.lproj` 両方の `Localizable.strings` にキーを追加する（日本語がプライマリ）。

## 全体規約

- **フォーマット**: SwiftFormat + SwiftLint（`.swiftformat` / `.swiftlint.yml`）。4 スペースインデント、150 文字行制限、trailing comma 必須。
- **ID**: 全テーブル・全エンティティで時系列ソート可能な UUID v7（`UUID.v7()`）を使う。
- **並行処理**: Swift 6 strict concurrency。詳細な規約は `Sources/Dahlia/CLAUDE.md`。
