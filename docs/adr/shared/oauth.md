# Desktop / Server / MCP の OAuth 契約

対象: Desktop・Server・remote MCP。採択: 2026-08-31〜09-03。

## Discovery と credential

通常 Server と Databricks Apps で同じ discovery-driven public client を使う。Apps の前段 proxy が認証と `CAN USE` を強制するため、その境界を Server 内 OAuth で迂回しない。

- protected-resource / authorization-server metadata を discovery し、Authorization Code、S256 PKCE、state、resource、callback `http://localhost:8020` を使う。scope は token 交換と refresh でも再送する。
- 事前登録した public client `databricks-cli` を共用し、`DAHLIA_CLOUD_OAUTH_CLIENT_ID` は deployment override とする。Desktop に secret を配布しない。`DAHLIA_CLOUD_URL` は既定 URL で、未設定でも手動 Server URL とローカル機能を使える。
- 通常 Server は userinfo、endpoint がない Apps は App audience token による `/api/session` で proxy 確定 identity を取得する。CLI profile や広い workspace 権限を前提にしない。
- 単一 actor が token、rotating refresh token、期限、resource、issuer、client ID、scope、利用者を所有する。Keychain credential は origin と client ID が一致する場合だけ再利用し、同時 refresh を集約する。新 credential の保存成功前に公開しない。
- revocation endpoint があれば失効を試み、結果にかかわらず local credential を削除する。失効失敗は通知し、endpoint がない場合は短期 token の自然失効を待つ。token、code、callback query、OAuth response body を log / telemetry / 表示用 error に含めない。

接続と Vault / runtime の関連は [Desktop account](../desktop/accounts.md)、移行・サインアウト時のデータ扱いは [同期](sync.md#正本とアカウント境界) に従う。サインインだけで Vault、Codex provider、CLI profile を変更しない。

## Scope

| Resource | Scope / authorization |
| --- | --- |
| Desktop main API | `all-apis`。models、Responses、artifacts、transactions、deltas、events、同期 content の bearer access に要求 |
| Remote MCP | `mcp` は全 MCP 操作、`mcp:read` は read tool と認証付き screenshot resource |
| OAuth / OIDC | `openid`、`profile`、`email`、`offline_access` は protocol scope で、API capability とは区別 |
| Trusted proxy | main API は検証済み proxy identity、合成 MCP identity は `mcp`。scope だけで owner / Vault 認可を代替しない |

Databricks Apps の Desktop 認可も `all-apis` を使う。DAB の `user_api_scopes` は forwarded OBO token の権限であり、`ai-gateway` と `files` を維持する。初期の `all-apis` 拒否と `api.model.*` / `api.artifact.*` / `api.sync.*` は廃止した。単一 Desktop client の細分 scope は独立した client の隔離にならず、再認可と互換経路を増やしたためである。

## 検証と移行

public App Connection に callback を登録し、single-use refresh rotation と有限の absolute session lifetime を有効にする。旧 `dahlia-macos` client は無効化し、既存 session は期限まで管理画面から失効可能にする。

release 前に対象 App で sign-in、session 取得、再起動後 refresh、sign-out と、App audience 外の無害な API への token 拒否を確認する。callback 到達だけでは実認証の証拠にしない。remote MCP の DPoP / CIMD と runtime 制限は [Artifact MCP](../server/artifacts.md#remote-mcp) に従う。
