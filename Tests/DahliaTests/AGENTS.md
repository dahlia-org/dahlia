# Tests/DahliaTests — テストガイド

テストは、変更した挙動を再現可能な入力で証明し、ユーザー環境や外部サービスに依存せずに実行できる状態を完了条件とする。

## 実行

```bash
swift test --filter SummaryServiceTests  # 対象スイートの例
swift test                              # 全スイート
```

最初に対象スイートを実行し、共有モデル、DB マイグレーション、録音ライフサイクルなど影響範囲が広い変更では全スイートまで広げる。

## 実行結果の判定

- exit 0 だけで成功と判断せず、`Test run with N tests` などの集計行を確認する。`xcode-select` が Command Line Tools を指す環境では、ビルドだけで 0 件のまま exit 0 になることがある。
- toolchain が原因で実行できない場合は、`xcode-select -p` の結果と未実行テストを報告する。`sudo xcode-select -s /Applications/Xcode.app` はシステム設定を変更するため、自動実行せずユーザーへ切り替えを依頼する。

## 実装規約

- 新規テストは Swift Testing（`import Testing`、`@Test`、`#expect`）で書き、ファイル全体を `#if canImport(Testing)` で囲む既存パターンに従う。
- XCTest はレガシーとして扱い、新規テストには使わない。既存 XCTest の修正や、依頼範囲外の一括変換はしない。
- `@testable import Dahlia` で内部 API にアクセスする。
- `@MainActor` 型を扱うスイートは、テストごとの回避策ではなくスイートの struct 自体を `@MainActor` にする。
- DB テストは `AppDatabaseManager(path: ":memory:")` を使う。ユーザーの Application Support にある DB へ触れない。
- ネットワーク、実カレンダー、Keychain、マイク、システム音声、ユーザー設定へ依存する処理は fake / stub / 一時領域に置き換える。

## テスト設計

- 正常系だけでなく、変更で壊れうる境界値、失敗、キャンセル、再実行を対象にする。
- 非同期テストは固定 sleep で成立させず、観測可能な状態やイベントを待つ。
- 不具合修正では、修正前に失敗し修正後に通る回帰テストを優先する。
