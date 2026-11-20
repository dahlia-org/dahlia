# Workspace 共有と管理者

対象: Server / Private Web。2026-09-12 の [Organization所有・共同編集](../shared/organization-personal-workspaces.md) に従う。Personal Organization、本人用 Workspace、登録時の作成方針は [Org配下の本人用Workspace](../shared/organization-personal-workspaces.md) に従う。

## 共有境界

Workspace は変更不能な Organization に所属する。Organization 所属だけでは内容へのアクセスを与えず、`workspace_permissions` の user / organization / team principal に `admin | editor | viewer` を付与する。有効 role は Admin、Editor、Viewer の順で解決する。Admin は Workspace 設定・共有・reset・削除・全内容の移管を行う。Admin と Editor は内容の作成・変更・削除・録音・AI 処理を行う。Viewer は読取のみを行う。

Header と accounts は同じ Better Auth セッション、招待、脱退、Team 管理 API を使う。Header の保護要求には検証済みの proxy identity を必須とし、Cookie の user との不一致を拒否する。Google ログインと OAuth provider は accounts 限定とする。Desktop と MCP の認証方式は変えない。

信頼済み Header と確認済み Google メールでは、ドメインの参加方式に従って Team へ参加する。初回登録時の自動参加と既存ユーザーの本人操作を分離し、再ログインだけでは再追加しない（[参加方式](#organizationの参加方式と作成削除2026-09-14)）。

検索候補は同じ Organization に所属するユーザー・組織・Team とする。他 Organization の既知 ID にも共有できるが、共通 membership のない principal は type と opaque ID だけを表示する。

permission 変更、membership 変更、Team / Organization 削除は、共通のアプリ側検査を同じ DB transaction 内で実行する。最後の Organization owner / member、Team member、有効な Workspace Admin を失う操作は rollback する。Team 権限には親 Organization の現在 membership も必要である。Team 作成者の membership も同じ transaction で確定する。アカウント削除は自己削除・管理者削除とも禁止する。

招待は verified login email との一致を要求し、既定で 48 時間後に失効する。招待 URL をコピーして共有し、外部 mail service は使わない。

## Organization governance

Organization owner / admin は配下 Workspace の ID・名前・revision・creator ID だけを取得できる。これは Workspace への read permission にはならず、Server 管理者 role だけでも利用できない。暗号化された名前は用途を限定して復号し、平文を重複保存しない。

Team Organization 配下の Workspace は確認付きで強制削除できる。確認時の revision と Workspace 変更 cursor を再検査し、変更があれば `409` で再確認させる。既存の storage cleanup、同期通知、操作者付き receipt を再利用する。Organization の削除には配下 Workspace が 0 件であることも必要である。

## Server 管理者

`auth.user.role` の `admin` と Better Auth admin plugin を使う。初期管理者の bootstrap は既存の方針に従う。Server 管理者はユーザー・組織ディレクトリと Server 設定を管理する。この権限だけでは Workspace 本文・共有設定・governance にアクセスできない。

impersonation session は read-only である。OAuth consent reference と署名 token claim にも引き継ぎ、Gateway / MCP の mutation を拒否する。広範な運用で必要になる quota は対象外である。

## Organizationの参加方式と作成・削除（2026-09-14）

ユーザー承認により、Header と確認済み Google メールの参加方式を定める。初回登録では、同じメールドメインが一致するすべての `auto_join` 組織に member として追加する（[Org配下の本人用Workspace](../shared/organization-personal-workspaces.md)）。既存ユーザーは再ログインや設定変更だけでは追加しない。

`organization_domains` は組織とドメインの複合主キーを持ち、同一ドメインを複数組織に登録できる。上限は 1 組織 10 件である。ドメインは正規化した完全一致とし、固定した MIT ライセンスの共有メールサービス一覧にあるドメインとそのサブドメインは拒否する。owner / admin の設定を信頼し、DNS 検証は行わない。

| 参加方式 | 一致する未所属者の操作 |
| --- | --- |
| `invite_only`（設定の既定値） | 候補には出さず、有効な招待で参加 |
| `need_approval` | 本人が申請し、owner / admin が承認 |
| `auto_join` | 初回登録で自動参加。既存ユーザーは本人が参加を実行 |

自主退会・除名後も現在の方式を適用する。別の参加禁止テーブルは持たない。候補では組織名・ロゴ・本人の申請状態だけを公開し、所属前にメンバーや Workspace を公開しない。所属によって Workspace 権限を暗黙に付与しない。

`organization_join_requests` は pending / approved / rejected / cancelled の履歴を保持し、同一ユーザー・組織の pending は 1 件に制限する。本人は取り消し、owner / admin は承認・却下できる。却下・取り消し後の再申請は許可する。設定変更で承認制の対象外になった pending は取り消し、既存の所属は維持する。承認と member 追加は同じ認可 transaction 内で確定する。招待の承認もこのロックを使い、既存の所属を再利用して強い役割を維持し、招待された Team を適用する。

Team Organization の作成・削除は Server 管理者のみが行う。作成者の認証 identity と指定する初期 owner は別に扱い、管理者自身は指定されなければ所属しない。一般の Better Auth の作成・削除経路は無効化し、公開管理 API から共通 OrganizationStore を呼ぶ。権限・種別・依存関係は操作直前の認可 transaction 内で確認し、impersonation からの変更を拒否する。配下 Workspace が残る Organization と、共有先 principal の削除で最後の有効な Workspace 管理者が失われる Organization は削除しない。

Web の削除は Server 管理画面に置く。Web / Desktop での作成では初期 owner を明示的に選択する。将来の課金連携も同じ Server 側の作成処理を使う。課金、Webhook、専用トークン、DNS、SSO / SCIM、通知メール、ゲスト・期限付き所属は範囲外である。pending は画面内で表示する。
