# Dahlia

[English](README.md)

macOS ネイティブのリアルタイム文字起こしアプリです。マイクとシステム音声を同時にキャプチャし、デバイス上で音声認識を行い、オプションで LLM による要約を生成します。

## 機能

- **デュアル音声キャプチャ** — マイク (AVAudioEngine) とシステム音声 (ScreenCaptureKit) を同時に録音
- **オンデバイス文字起こし** — Apple Speech フレームワークによるリアルタイム音声認識
- **LLM 要約** — OpenAI 互換 API を使った構造化された要約の生成（オプション）
- **プロジェクト管理** — Vault/プロジェクト階層でファイルシステムと同期した文字起こしの整理
- **会議検出** — 3 層の検出レイヤーによる会議セッションの自動検出
- **スクリーンショット** — 文字起こしにスクリーンショットを添付してマルチモーダル要約に活用
- **バイリンガル UI** — 日本語（メイン）と英語

## 動作環境

- macOS 26 以降
- Swift 6.2
- Xcode 26 以降（Swift ツールチェーン用）

## ビルド & 実行

```bash
# デバッグビルド・実行（署名なし）
swift build && swift run

# コード署名付きデバッグビルド（Data Protection Keychain + Touch ID が有効）
./scripts/run-dev.sh

# リリース用 .app バンドルのビルド
./scripts/build-app.sh && open Dahlia.app

# テスト
swift test

# リリースビルド + notarization + staple + 配布用 zip 再作成
./scripts/notarize.sh

# 整形 + Lint
./scripts/lint.sh
```

> **注意:** `swift run` は署名なしバイナリのため Data Protection Keychain を使用できません。フル機能を利用するには `run-dev.sh` を使用してください。

`build-app.sh` または `notarize.sh` の実行前に `SENTRY_DSN` を設定すると、生成される release アプリの `Info.plist` に DSN を埋め込み、Finder 起動でも Sentry を有効化できます。Debug 実行では送信しないため、`swift run` と `run-dev.sh` は既定で Sentry イベントを送信しません。

Sentry を使う場合、`run-dev.sh` と `build-app.sh` は `SENTRY_AUTH_TOKEN` が設定されていれば `Dahlia.dSYM` のアップロードも試みます。事前に `sentry-cli` をインストールしてください。

```bash
export SENTRY_DSN="https://<key>@o0.ingest.sentry.io/<project>"
brew install getsentry/tools/sentry-cli
```

notarization の初回実行前に、`notarytool` のキーチェーンプロファイルを作成してください。

```bash
xcrun notarytool store-credentials "dahlia-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

`./scripts/notarize.sh` は `NOTARY_PROFILE` 環境変数（既定値: `dahlia-notary`）を使い、staple 済みの `Dahlia.zip` を作成します。

## アーキテクチャ

```
AudioCaptureManager (マイク / AVAudioEngine)
SystemAudioCaptureManager (システム音声 / ScreenCaptureKit)
    ↓ onAudioBuffer
AudioSourcePipeline → CapturedAudioChunk
    ↓ AudioFrameRouter (音源ごとに物理 capture 1 回)
    ├─ BatchAudioFileWriter (欠落のない録音保存)
    └─ AudioBufferBridge → SpeechTranscriberService (低遅延文字起こし)
        ↓ TranscriptionEvent
        ├─ TranscriptStore (リアルタイム状態)
        └─ LiveCaptionStore (一時字幕)
    ↓ Combine debounce(500ms)
MeetingPersistenceService → SQLite (GRDB)
```

### プロジェクト構成

```
Sources/Dahlia/
├── Audio/          # 音声キャプチャ（マイク & システム）
├── Database/       # GRDB モデル、マイグレーション、リポジトリ
├── Models/         # ドメインモデル
├── Services/       # LLM、Vault 同期、会議検出、Keychain
├── Speech/         # 音声認識パイプライン
├── Utilities/      # ヘルパー（UUID v7、ローカライゼーション等）
├── ViewModels/     # CaptionViewModel、SidebarViewModel
├── Views/          # SwiftUI ビュー
└── Resources/      # ローカライズ文字列、アセット
```

## 依存ライブラリ

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite ツールキット
- [sentry-cocoa](https://github.com/getsentry/sentry-cocoa) — Release ビルドのクラッシュレポート

## ライセンス

All rights reserved.
