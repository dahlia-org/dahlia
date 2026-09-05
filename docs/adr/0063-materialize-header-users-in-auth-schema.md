# ADR-0063: Header identityを共通Auth userへ射影する

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0058, ADR-0061

## Context

ADR-0061はheader認証で`auth` schemaを作らず、Vault RLSをtransaction-local identityだけで評価する構成を選んだ。
RLSの分離には有効だが、application tableからuserを参照する外部キーを持てず、認証方式ごとにmigration集合も変わる。
Header proxyがすでに検証したuser identityもServer内のuser directoryへ残らない。

## Decision

- 機械生成したBetter Auth schemaを認証方式にかかわらず作成する。PostgreSQL/Lakebaseでは生成Auth migrationと
  Dahlia application migrationのledgerを分けたまま、常にAuth、applicationの順で適用する。
- Better Auth runtime、session、OAuth endpointはaccounts modeだけで有効化する。Header modeでは検証済みidentityを
  `auth.user`へrequest開始時にJIT射影し、`X-Forwarded-User`をID、未指定時は正規化済みemailをIDとする。
- Header userのnameとemailは後続requestで更新する。同じemailが別IDですでに存在する場合は自動統合せずfail closedにする。
- `core.search_index_jobs.owner_user_id`と`core.vault_permissions.granted_by_user_id`は`auth.user.id`を参照する。
  polymorphicなpermissionの`principal_id`は`principal_type`と組で扱うため外部キーにしない。
- Vault/content RLSへ渡すtransaction-local identityは`app.user_id`だけとする。organization permissionはRLS関数が
  `auth.member`を直接参照し、header deployment permissionはそのdatabaseの認証済みuser全体へ適用する。
- 未リリースdatabaseは新しいbaselineから再作成し、旧migration historyや既存dataの変換は行わない。

## Consequences

- `auth <- core <- content`の参照方向を認証方式に依存せず適用でき、migration集合も共通になる。
- Header deploymentでもuser一覧と明確なuser参照外部キーを利用できる一方、不要なBetter Auth endpointは公開されない。
- Proxyが同じ人物へ異なる`X-Forwarded-User`を送ると、同一emailならrequestが拒否される。IDとemailの両方が変わる場合は
  別userとなり、既存permissionを自動移行しない。
