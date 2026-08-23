# ADR-0039: Databricks CLI の外部導入と workspace 起点の認証を案内する

- Status: Accepted
- Date: 2026-08-24
- Amends: ADR-0003 and ADR-0021

## Context

Databricks provider は user `HOME` にある Databricks CLI の OAuth profile を利用するが、非エンジニアの Mac には CLI や認証済み profile が存在しない場合がある。Dahlia が CLI を同梱すると、更新と再配布ライセンスの管理もアプリの責務になる。

## Decision

- Databricks CLI は同梱・自動ダウンロードせず、公式手順、Databricks License、Privacy Notice を利用前に表示する。
- CLI 未検出時は固定された Homebrew command を Terminal.app の新規 session で実行する。Apple Events が拒否された場合は command を clipboard にコピーして Terminal.app を開く。
- 設定画面の「プロファイルを新規作成」から開く dialog で profile 名（初期値 `DEFAULT`）と workspace root の HTTPS URL を受け取り、`databricks auth login --host <url> --profile <name>` を引数配列で実行する。
- 指定した名前が同じ host の OAuth profile なら再利用する。別の host または認証方式の既存 profile は上書きしない。
- token、Codex config、app-server reload、model 一覧まで検証できた場合だけ設定を有効化する。失敗時は以前の有効な Codex config を復元し、dialog 内で修正できる状態を保つ。dialog を閉じた場合は以前の provider 選択も復元する。
- 既存 OAuth profile の選択 UI は互換性のため残す。

## Consequences

- CLI の binary、LICENSE、NOTICE は app bundle に追加されず、CLI と credential は引き続き Databricks が管理する。
- Homebrew 自体は導入しないため、未導入時は Terminal の失敗内容と公式手順が復旧経路になる。
- Terminal.app の操作には Apple Events entitlement と usage description が必要になる。
- CLI をインストールして Dahlia に戻ると再検出され、アプリ再起動なしで認証を続行できる。

## Relationship

ADR-0003 の共有 Codex app-server と ADR-0021 の user `HOME` 継承は維持する。この ADR は Databricks CLI の配布境界、初回導入、workspace 起点の OAuth profile 作成を追加する。

## References

- [ADR-0003](0003-use-a-shared-codex-app-server.md)
- [ADR-0021](0021-preserve-user-home-for-databricks-authentication.md)
- [Databricks CLI installation](https://docs.databricks.com/aws/en/dev-tools/cli/install)
- [Databricks CLI license](https://github.com/databricks/cli/blob/main/LICENSE)
- [Databricks Privacy Notice](https://www.databricks.com/legal/privacynotice)
- [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
