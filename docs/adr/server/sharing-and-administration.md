# Vault 共有と管理者

対象: Server / Private Web。採択: 2026-09-02〜09-03。

## 共有境界

個人所有 Vault を owner が特定 Organization / Team へ明示的に read-only 共有する。write、delete、共有設定変更は owner のみ。共有機能は常に有効とし、機能を無効化する環境設定は設けない。

- accounts mode は Better Auth Organization / Team を使う。共有先追加時の owner の所属と閲覧時の現在 membership を確認し、脱退・member 削除で read を失効させる。
- header user は ID / slug が `external`、初期表示名が `Default Organization` の Organization へ JIT 登録する。最初の user を変更不能な owner、以降を member とする。初期 Team は作らず、最後の Team も削除可能にする。
- accounts mode でも最初に作成された user の認証済み request で、既定の `external` Organization の owner membership を初期化する。既存 admin がいる DB にも適用し、2人目以降の accounts user は自動追加しない。組織と初期 owner membership の作成は atomic に行う。作成後は accounts の所属削除・role 変更を維持し、初期 user が削除されても次の user を自動追加しない。既存の組織 owner metadata を維持する。旧既定名 `external` は認証済みアクセス時に新表示名へ更新し、手動変更した名前と既存 Team は保持する。
- header mode の Team と membership 管理は 既定 Organization owner のみ。招待、脱退、Organization member 削除を提供しない。accounts は標準 API、sessionless header は同じ Auth table を扱う Dahlia API を使う。
- permission は `user | organization | team` に統一する。transaction-local user ID と現在の Auth membership による認可は [Database](database-and-identity.md#vault-permission) に従う。共有先一覧は owner に全件、member に権限のある共有先だけを返し、他組織の情報を開示しない。
- Organization / Team 削除 hook は permission を削除する。cleanup が失敗して stale row が残っても membership 不在から read 権限は発生しない。

accounts の招待は verified login email と招待 email の一致を要求し、既定48時間で失効する。一度だけ表示する招待 URL を owner がコピーし、再招待は未処理分を取り消す。外部 mail service と email domain 制限は追加しない。

## Server 管理者

`auth.user.role` の `admin` を管理権限の唯一の正本とし、Better Auth admin plugin を runtime と schema 生成で使う。認証方式にかかわらず最初の user を初期 admin にし、0人になれば次の認証済み request で最古 user を再昇格する。

`/api/admin/**` と管理画面は同じ role を使い、accounts では標準 admin API も公開する。Dahlia API は最後の admin の降格を拒否するが、標準 API の動作は変更しない。impersonation session は read-only とし、OAuth consent reference と署名 token claim にも引き継ぎ、Gateway / MCP mutation を拒否する。

Server 管理者は `/api/admin/users` と `/api/admin/organizations` で、所属に依存しないユーザー・組織のディレクトリ情報をページ単位で取得できる。この権限は Vault の所有・共有権限を変更せず、他ユーザーのミーティング内容へのアクセスを付与しない。Private Web はサーバー管理をサイドバー下部に分離し、アカウントメニューにはアカウント設定と active Organization の切り替えを置く。

## 経緯と未解決事項

初期の header deployment 全員共有を通常の Organization / Team に統合し、旧専用 API は404にした。Server 管理者の環境変数と独自 table も廃止した。共有は共同編集や組織別 provider を許可する決定ではない。

広範な public multi-tenant / header deployment での運用前に per-owner quota と保持方針が必要。header から accounts へ切り替えても External Organization を自動移行・削除しない。当時の未リリース DB は生成 baseline から再作成したが、released data の破壊的移行を許可するものではない。
