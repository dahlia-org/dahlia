# ADR-0053: Vault ごとに Codex アカウントを選択する

- Status: Accepted
- Date: 2026-09-01
- Supersedes in part: ADR-0051, ADR-0052
- Builds on: ADR-0021, ADR-0029

## Context

Dahlia アカウントの AI Gateway を Desktop の要約とチャットから利用するには、どの credential と Codex 設定を使うかを
Vault ごとに決める必要がある。これは meeting sync とは独立した consumer であり、ADR-0052 の「Vault 関連は sync 実装と
同時に追加する」という保留条件では AI provider を安全に分離できない。

Codex app-server は `CODEX_HOME` の root provider に対して model discovery と Responses を実行する。単一 home の provider を
切り替えると認証情報とモデル設定が Vault 間で混ざるため、アカウント境界には home の分離が必要になる。

## Decision

- Vault は nullable な Dahlia account connection ID を保持する。`nil` は stable なローカルアカウントを表し、接続削除時は
  `ON DELETE SET NULL` でローカルへ戻す。この関連は AI provider 利用のために導入し、sync の有効化を意味しない。
- ローカルアカウントだけが ChatGPT Subscription または Databricks AI Gateway を選択できる。Dahlia アカウントはその接続先の
  Dahlia AI Gateway だけを使う。これにより ADR-0051 の「Cloud sign-in は Codex provider を変更しない」という決定を、
  sign-in を開始した Vault への関連付けに限って置き換える。
- 既存の `Application Support/Dahlia/Codex` をローカルアカウントの `CODEX_HOME` として維持する。Dahlia アカウントには接続 UUID
  ごとの private home を割り当て、provider 設定と Codex の状態を分離する。
- app-server は一プロセスのままとする。Vault の account/provider context が変わると新規操作を待機させ、進行中操作を drain して
  対象 `CODEX_HOME` で再起動する。アカウント間の並列実行と process pool は導入しない。
- モデル一覧と生成はどちらも app-server の root provider を使う。provider 固有の model discovery client や cache は持たない。
- Dahlia access token は接続ごとの既存 Cloud service actor が更新し、private local broker を介した Codex `auth.command` へ動的に返す。
  token を config、環境変数、log に保存しない。
- provider、Databricks profile、要約とチャットの model ID / reasoning effort は Vault に保存する。既存 Vault は従来のグローバル設定を
  引き継ぎ、新規 Vault は作成時に現在の Vault の値を継承する。
- account connection の origin 一意制約は維持する。同一 origin 上の複数 remote account を Vault ごとに使い分けることは対象外とする。

## Consequences

- ローカル、Cloud、複数 Server の Codex 認証と設定は `CODEX_HOME` 境界で混ざらない。
- account/provider 切替中は app-server の drain と再起動を待つため、AI 操作を短時間開始できない。
- 接続削除は関連 Vault をローカルへ戻し、その接続専用の Codex profile data も削除するが、Vault、meeting、録音、文字起こし、
  sync data は削除しない。
- 既存設定の意味と保存場所をアプリ共通から Vault 単位へ変更するため、リリース準備時は minor version を増分する。
