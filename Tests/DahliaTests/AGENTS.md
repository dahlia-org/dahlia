# Tests/DahliaTests — テスト規約

## 実行

```bash
swift test                                # 全テスト
swift test --filter SummaryServiceTests   # 型名でフィルタ
```

> **注意**: `xcode-select` が Command Line Tools を指している環境では、`swift test` がビルドだけ行いテストを 1 件も実行せずに exit 0 で終了する（`Test run with N tests` の集計行が出ない）。集計行が出ていなければテストは走っていない。`sudo xcode-select -s /Applications/Xcode.app` で Xcode の toolchain に切り替える。

## 規約

- 新規テストは Swift Testing（`import Testing`、`@Test`、`#expect`）で書く。ファイル全体を `#if canImport(Testing)` で囲む既存パターンに従う。
- XCTest のテストはレガシー。新規追加はしない（既存テストの修正は可）。
- DB を使うテストは `AppDatabaseManager(path: ":memory:")` でインメモリ DB を生成する。実ファイルやユーザーの Application Support には触れない。
- `@testable import Dahlia` で内部 API にアクセスする。
- `@MainActor` 型をテストするスイートは struct 自体に `@MainActor` を付ける。
