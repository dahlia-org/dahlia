# エージェントによる MCP 経由の外部サービス操作

対象: Desktop 内蔵チャットと Product tenet T4。採択: 2026-11-07。ユーザー承認済み。

## 決定

Dahlia のエージェント（内蔵チャット）が MCP を介して外部サービスを読み書きすることを許す。T4 が禁じるのは、
Dahlia 自身が外部サービスごとの統合（認証、レート制限、スキーマ、権限モデル）を実装することであり、
MCP server が統合を持ち、エージェントがその tool を呼ぶ構成は禁じない。

最初の対象は Databricks workspace の Unity AI Gateway の外部サービス MCP（`system.ai.gmail` など）とし、利用者が
アカウントごとに登録する。実行方式は[内蔵 Pi runtime](pi-runtime.md#unity-ai-gateway-の-mcp)に従う。

## 理由

- 外部サービスごとの認証、権限、スキーマ変更への追従は MCP server（ここでは Databricks）が持つ。Dahlia が持つのは
  MCP の URL と、MCP server（Databricks workspace）への sign-in だけで、T4 の根拠（統合の都合でアプリの中核が壊れる）に当たらない。
- MCP を使うエージェントが外部の AI でも内蔵チャットでも、Dahlia 側に増える統合実装は同じく無い。内蔵チャットだけを
  除外する理由がない。

## 制約

- 中核機能（録音、確定文字起こし、要約）は外部サービスの MCP に依存しない。MCP の失敗はチャットの tool の失敗に留める（T3、T5）。
- 既定は何も登録せず、ユーザーがアカウントごとに登録する。sign-in が切れたら自動で開き直さず、再サインインを促す。
- 読み取り以外の tool はチャットの承認方式に従う。Dahlia が登録した MCP server だけを承認でき、それ以外は拒否する。
- MCP の結果は untrusted data として扱い、指示として実行しない。
- Dahlia を業務データの正本にする MCP 連携は、MCP 経由でも採用しない（T2 が優先する）。
