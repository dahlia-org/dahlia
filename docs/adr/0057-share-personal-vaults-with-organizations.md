# ADR-0057: 個人所有 Vault を organization へ明示共有する

- Status: Accepted
- Date: 2026-09-02
- Amends: ADR-0056
- Builds on: ADR-0043, ADR-0044, ADR-0051

## Context

同期済み meeting を Google Drive などと同様に自組織の特定メンバーから参照できるようにしたい。
Vault の所有権を organization へ移す必要はなく、共同編集も不要である。一方、transcript、screenshot、OCR、AI caption は
機微な内容を含むため、認証方式や deployment の種類だけを根拠に暗黙共有してはならない。

## Decision

- Vault は引き続き単一 user permission による個人所有とする。owner は一つの Vault を複数の特定
  organization へ read-only 共有でき、write、delete、共有設定の変更は owner だけが行う。
- Better Auth の accounts mode は組み込み organization plugin を使う。共有先追加時に owner が現在の member であることを検証し、
  閲覧時にも `auth.member` を評価する。member 削除は即時に閲覧権限を失効させる。
- header mode は既定 owner-only とする。owner が `Share with everyone on this Dahlia Server` を明示した Vault だけを、
  同じ trusted proxy deployment の認証済みユーザーへ read-only 共有する。
- PostgreSQL／Lakebase の SELECT policy は transaction-localな`app.user_id`からowner、明示share、現在の`auth.member`
  membershipを一段で評価する。header deployment permissionは、そのDBを使う認証済みuser全体への明示共有として扱う。
  write policy は owner 一致のまま変えない。SQLite／D1 は同じ条件を application query で強制する。
- share row の一覧は owner には全件を、organization member には自分が所属する organization の行だけを、header user には
  `header_deployment` 行だけを返す。他 organization の共有先を開示しない。
- organization invitation は verified login email と招待 email の一致を要求し、既定48時間で失効する。外部 mail service は追加せず、
  owner が一度だけ表示される招待 URL をコピーする。再招待は未処理 invitation を取り消して再発行する。
  自組織内共有を想定するが、email domain 制限は設けない。
- shared read は Private Web と Server MCP の既存 meeting read surface を再利用する。Server から desktop への同期と共同編集は追加しない。
- 共有は明示permissionが存在する場合だけ有効になるため、deployment-wide capability flagは持たない。
  public multi-tenantまたは広範なheader deploymentで共有を運用する前にper-owner quotaと保持方針を追加する。

## Consequences

- team sharing と read permission management は product scope に入るが、所有権、更新権限、ローカル正本は個人のまま保たれる。
- Better Auth に organization、member、invitation と session の active organization metadata が増える。
- organization 削除 hook は share row を除去する。hook が失敗して stale row が残っても membership が存在しないため権限は発生しない。
- header deployment の全員共有は明示 share row に統一され、deployment 種別による暗黙公開を持たない。
- 同じdatabaseをaccounts/header認証間で切り替えない。header deployment permissionは認証方式ではなくdatabase境界に紐づく。
