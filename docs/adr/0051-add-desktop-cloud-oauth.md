# ADR-0051: Desktop から Dahlia Cloud OAuth に接続する

- Status: Accepted
- Date: 2026-08-31
- Builds on: ADR-0044, ADR-0049

## Context

Desktop は通常の Dahlia Server と Databricks Apps 上の Dahlia Server の両方へ接続する。通常 Server は内蔵 OAuth を持つが、Databricks Apps では前段 proxy が利用者認証と `CAN USE` を強制するため、Desktop が Server 内 OAuth を直接開始すると認証境界を迂回する。

## Decision

- build 時の `DAHLIA_CLOUD_URL` は「Dahlia Cloud」の既定接続先に使う。未設定でもサインイン画面から Server URL を指定でき、ローカル機能は変えない。
- App URL の protected-resource metadata と authorization-server metadata を discovery し、固定 callback `http://localhost:8020`、Authorization Code、S256 PKCE、`state`、`resource` を使う。認可時の `scope` はtoken交換とrefreshでも再送する。
- Cloud とセルフホスト Server は共通の事前登録済み public client `databricks-cli` を使い、`DAHLIA_CLOUD_OAUTH_CLIENT_ID` は deployment 向け override にだけ使う。secret を Desktop へ配布しない。Databricks proxy では metadata の scopes と `offline_access` のみを要求し、`all-apis` や client に未割当の OIDC scopes は要求しない。token response が要求外 scope または `all-apis` を返した場合も拒否する。通常 Server では `openid profile email offline_access` も要求する。
- userinfo endpoint があれば通常 Server の利用者情報を取得する。endpoint がない Databricks Apps では App audience token で `/api/session` を呼び、proxy が確定した利用者情報を取得する。Server 内 OAuth は開始しない。
- access token、rotating refresh token、期限、resource、issuer、client ID、scope、利用者を単一 actor が所有する。credential は Keychain に保存し、Cloud origin と client ID が一致する場合だけ再利用する。token refresh の同時要求は一つに集約し、新 credential の保存成功後にだけ公開する。
- sign-out は revocation endpoint が metadata にある場合は失効成功後に削除する。endpoint がなければローカル credential だけを削除する。
- token、authorization code、callback query、OAuth response body は log、telemetry、表示用 error に含めない。
- Cloud sign-in は Codex provider、Databricks CLI profile、artifact、meeting sync を変更しない。

## Deployment requirements

- Desktop 用 public OAuth App Connection に上記 callback を事前登録し、client secret を発行しない。
- 旧 `dahlia-macos` Server client は起動時に無効化する。既存 session は期限切れまで session 管理に表示し、利用者が失効できる状態を維持する。
- single-use refresh token rotation と有限の absolute session lifetime を有効にする。
- Databricks Apps の利用者には対象 App の `CAN USE` を付与する。広い workspace 権限や CLI profile は前提にしない。
- release 前に対象 App で sign-in、`/api/session`、再起動後 refresh、sign-out を確認する。取得 token を App audience 外の無害な workspace API に送って拒否されることを必須 gate とする。

## Consequences

- 同じ Desktop client ID で通常 Server と Databricks Apps の discovery-driven OAuth を扱える。
- revocation endpoint がない deployment の sign-out 後は短期 access token の自然失効を待つ。
- 将来の Cloud API は `DahliaCloudService.validAccessToken()` を使えるが、今回それらの機能は接続しない。
