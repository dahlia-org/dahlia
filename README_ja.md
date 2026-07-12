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

# バージョン付き DMG のビルド + 署名 + notarization + staple
./scripts/notarize.sh

# 対応する GitHub Release を作成し、公証済み DMG を添付
./scripts/create-github-release.sh

# 整形 + Lint
./scripts/lint.sh
```

> **注意:** `swift run` は署名なしバイナリのため Data Protection Keychain を使用できません。フル機能を利用するには `run-dev.sh` を使用してください。

`build-app.sh` または `notarize.sh` の実行前に `SENTRY_DSN` を設定すると、生成される release アプリの `Info.plist` に DSN を埋め込み、Finder 起動でも Sentry を有効化できます。Debug 実行では送信しないため、`swift run` と `run-dev.sh` は既定で Sentry イベントを送信しません。

`build-app.sh` と `run-dev.sh` は外部へファイルをアップロードしません。`notarize.sh` で Sentry を有効にしたリリースを作る場合は、`SENTRY_AUTH_TOKEN` と `sentry-cli` を必須とし、実行ファイルと dSYM の UUID が一致することを検証してから、公証成功後に dSYM をアップロードします。

```bash
export SENTRY_DSN="https://<key>@o0.ingest.sentry.io/<project>"
export SENTRY_AUTH_TOKEN="<organization-auth-token>"
brew install getsentry/tools/sentry-cli
```

既定でアップロードするのはデバッグシンボルだけです。ソースコンテキストは Sentry 上でアプリのソースコードを閲覧可能にするため、必要な場合に限り `SENTRY_INCLUDE_SOURCES=1` で明示的に有効化します。`SENTRY_AUTH_TOKEN` は `.env.local`、Keychain、または CI の secret で管理し、アプリには埋め込みません。各リリースの dSYM は非公開の保管先にも残し、公開 GitHub Release には添付しないでください。

アプリはクラッシュスタックと明示的に捕捉したエラーを送信しますが、既定 PII、HTTP 失敗の自動捕捉、ネットワーク breadcrumb、パフォーマンストレース、スクリーンショット、ソース送信は無効です。追加の防御として、Sentry プロジェクト側でもデータスクラビングと IP アドレス除去を設定してください。捕捉するエラーやタグには、文字起こし、音声、カレンダー詳細、API ペイロード、認証情報、ユーザー固有パスを含めないでください。

notarization の初回実行前に、`notarytool` のキーチェーンプロファイルを作成してください。

```bash
xcrun notarytool store-credentials "dahlia-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

`./scripts/notarize.sh` は `NOTARY_PROFILE` 環境変数（既定値: `dahlia-notary`）を使い、署名・notarization・staple 済みの `Dahlia-<version>.dmg` を作成します。バージョンは `Resources/Info.plist` の `CFBundleShortVersionString` から取得します。

リリースを公開するには GitHub CLI（`gh`）をインストールして認証し、バージョン変更を含むすべてのソース変更をコミットして push してから、次を実行します。

```bash
./scripts/notarize.sh
./scripts/create-github-release.sh
```

`create-github-release.sh` は DMG の署名、公証チケット、ファイル名、ディスクイメージの整合性を検証します。その後、現在のコミットに `v<version>` タグを作成（既存タグがある場合は同じコミットを指すことを確認）し、自動生成したリリースノートを含む GitHub Release を作成して DMG を添付します。作業ツリーに未コミットの変更がある場合は公開しません。

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
