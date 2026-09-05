# ADR-0061: Vault RLS を Better Auth schema から分離する

- Status: Accepted
- Date: 2026-09-03
- Amends: ADR-0057, ADR-0058, ADR-0059

## Context

Vault permission の `user` principal は既存 Artifact の personal workspace IDを流用し、RLS は organization membershipを
`auth.member`から直接評価していた。この構成では`principal_type`があるにもかかわらずuser IDへ`personal:`名前空間を重ね、
Better Authを使わないheader deploymentでもRLSのDDLとmigrationが`auth` schemaを必須にする。

## Decision

- `core.vault_permissions`の`user` principal IDと`granted_by_principal_id`には、認証方式から取得した生の`user_id`を保存する。
  `principal_type`をID名前空間とし、ownerとdirect user memberは`principal_type = 'user'`とIDを必ず組で比較する。
- `Identity.workspaceId = personal:<userId>`は既存ArtifactとOAuth claimの互換性のため残すが、Vault permissionには使わない。
- Serverは各identity transactionの開始時に、検証済みuser ID、Better Auth organization ID一覧、header deployment principalを
  transaction-local settingへ設定する。accounts modeのorganization一覧は各requestで`auth.member`から読み直し、脱退を次のrequestで失効させる。
- Vault/content RLSは`core.vault_permissions`とtransaction-local settingだけを評価し、`auth` schemaを参照しない。
  setting未指定時はdenyし、共有無効時はmember permissionを無視する。
- PostgreSQL/Lakebase migrationは機械生成するBetter Auth baselineとDahlia application baselineへ分離する。
  accounts modeはauth、applicationの順に適用し、header modeはcore/contentを含むapplication baselineだけを適用する。
  migration ledgerはapplication dataから分離し、それぞれ`drizzle.__dahlia_auth_migrations`と
  `drizzle.__dahlia_server_migrations`を使う。
- SQLite/D1はschema namespaceを持たず、既存の単一baselineを維持する。application queryはPostgreSQLと同じprincipal判定を行う。
- 未リリース環境の既存databaseは移行せず、新しいbaselineから再作成する。

## Consequences

- Databricks Appsのheader deploymentはBetter Auth tableなしでVault/content RLSを利用できる。
- Better Auth生成schemaをDahlia固有の認可設計に合わせて手編集する必要がない。
- user、organization、header deploymentのID衝突は`principal_type`で分離される。認証方式自体を後から変更した場合のidentity対応付けは
  自動化せず、従来どおり再同期または明示的な移行を必要とする。
