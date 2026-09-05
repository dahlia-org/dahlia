# Vault 共有と管理者

対象: Server / Private Web。採択: 2026-09-02〜09-03。

## 共有境界

個人所有 Vault を owner が特定 Organization / Team へ明示的に read-only 共有する。write、delete、共有設定変更は owner のみ。`DAHLIA_SYNC_SHARING_ENABLED` 明示指定時だけ共有を有効にし、既定無効でも owner の同期と read は維持する。

- accounts mode は Better Auth Organization / Team を使う。共有先追加時の owner の所属と閲覧時の現在 membership を確認し、脱退・member 削除で read を失効させる。
- header user は ID / slug / name が `external` の Organization へ JIT 登録する。最初の user を変更不能な owner、以降を member とし、`external-default` Team と最初の owner membership も変更不能にする。自動 Team 登録は最初の owner だけ。
- header mode の Team と membership 管理は External Organization owner のみ。招待、脱退、Organization member 削除を提供しない。accounts は標準 API、sessionless header は同じ Auth table を扱う Dahlia API を使う。
- permission は `user | organization | team` に統一する。transaction-local user ID と現在の Auth membership による認可は [Database](database-and-identity.md#vault-permission) に従う。共有先一覧は owner に全件、member に権限のある共有先だけを返し、他組織の情報を開示しない。
- Organization / Team 削除 hook は permission を削除する。cleanup が失敗して stale row が残っても membership 不在から read 権限は発生しない。

accounts の招待は verified login email と招待 email の一致を要求し、既定48時間で失効する。一度だけ表示する招待 URL を owner がコピーし、再招待は未処理分を取り消す。外部 mail service と email domain 制限は追加しない。

## Server 管理者

`auth.user.role` の `admin` を管理権限の唯一の正本とし、Better Auth admin plugin を runtime と schema 生成で使う。認証方式にかかわらず最初の user を初期 admin にし、0人になれば次の認証済み request で最古 user を再昇格する。

`/api/admin/**` と管理画面は同じ role を使い、accounts では標準 admin API も公開する。Dahlia API は最後の admin の降格を拒否するが、標準 API の動作は変更しない。impersonation session は read-only とし、OAuth consent reference と署名 token claim にも引き継ぎ、Gateway / MCP mutation を拒否する。

## 経緯と未解決事項

初期の header deployment 全員共有を通常の Organization / Team に統合し、旧専用 API は404にした。Server 管理者の環境変数と独自 table も廃止した。共有は共同編集や組織別 provider を許可する決定ではない。

広範な public multi-tenant / header deployment での運用前に per-owner quota と保持方針が必要。header から accounts へ切り替えても External Organization を自動移行・削除しない。当時の未リリース DB は生成 baseline から再作成したが、released data の破壊的移行を許可するものではない。
