# Dahlia — リポジトリ作業ガイド

## 目的

Dahlia は、マイクとシステム音声を同時にキャプチャし、Apple Speech framework でリアルタイム文字起こしを行う macOS アプリ。任意で LLM 要約も生成する。

依頼された成果を、既存の録音・文字起こし品質とユーザーデータを保ちながら完成させる。明示的に変更を求められていない挙動は維持する。

## 指示の適用範囲

このファイルはリポジトリ全体に適用する。編集対象により近い `AGENTS.md` がある場合は、作業前に読み、より具体的な指示を優先する。

| 対象 | 追加の指示 |
|------|------------|
| `Sources/Dahlia/` | アーキテクチャ、並行処理、UI: `Sources/Dahlia/AGENTS.md` |
| `Sources/Dahlia/Database/` | GRDB とマイグレーション: `Sources/Dahlia/Database/AGENTS.md` |
| `Tests/DahliaTests/` | テスト実装と実行確認: `Tests/DahliaTests/AGENTS.md` |
| `scripts/` | SwiftPM のビルド、署名、notarize、lint スクリプト |

`CLAUDE.md` は同じ階層の `AGENTS.md` への互換シンボリックリンクであり、内容を二重管理しない。

## 技術と不変条件

- Swift 6.2 / SwiftUI / macOS 26+ / Swift 6 strict concurrency。
- ビルドシステムは Swift Package Manager のみ。Xcode プロジェクトは生成しない。
- SwiftPM の外部依存は GRDB.swift と sentry-cocoa の 2 つだけ。加えて、固定バージョンの OpenAI Codex CLI を
  Cargo でビルドし、アプリの実行時ヘルパーとして同梱する。依存の追加・更新は事前に確認を取る。
- リリース済みユーザーの DB を破壊しない。登録済みマイグレーションは変更せず、Database の `AGENTS.md` に従って新しいマイグレーションを追加する。

## 作業範囲と承認

- 回答、説明、レビュー、診断、計画の依頼では、必要なファイルやログを調査して結果を報告する。変更も明示された場合だけ編集する。
- 変更、実装、修正の依頼では、必要なローカル編集と非破壊的な検証を進める。既存の未コミット変更を保持し、依頼と無関係な差分を直さない。
- 破壊的操作、外部への書き込み、または依頼範囲の実質的な拡大には、実行前に確認を取る。

## コマンド

```bash
swift build                       # Debug ビルド
swift run                         # 未署名 Debug 実行
./scripts/run-dev.sh              # Debug + codesign（フル機能の動作確認に推奨）
./scripts/build-app.sh            # Release .app バンドル
swift test                        # 全テスト
swift test --filter SummaryServiceTests  # 対象スイートの例
CI=true ./scripts/lint.sh         # 変更せず SwiftFormat / SwiftLint を検査
```

`swift run` は未署名のため Data Protection Keychain を使えない。Keychain と Touch ID を含む動作確認には `run-dev.sh` を使う。

## 完了条件

- 依頼された成果と、このファイルおよび対象階層の制約を満たしている。
- Swift の変更は `swift build`、変更した挙動は対象テスト、広範な変更は必要に応じて `swift test` で検証している。Swift ソースの変更では `CI=true ./scripts/lint.sh` も確認する。
- テストは終了コードだけでなく、出力の集計行で対象テストが実際に実行されたことを確認する。
- 公開挙動、設定、スキーマが変わる場合は、対応するテスト、ローカライズ、ドキュメントも更新する。検証できない項目は、未実行のコマンド、理由、次の確認を明記し、成功と扱わない。
