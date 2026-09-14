# Workspace 共有と管理者

対象: Server / Private Web。2026-09-12の[Organization所有・共同編集](../shared/organization-vaults.md)により更新。

## 共有境界

Workspaceは変更不能なOrganizationに所属する。Organization所属だけでは内容へのアクセスを与えず、`workspace_permissions` のuser / organization / team principalに `admin | editor | viewer` を付与する。有効roleはAdmin、Editor、Viewerの順で解決する。AdminはWorkspace設定・共有・reset・削除・全内容移管を行い、AdminとEditorは内容の作成・変更・削除・録音・AI処理を行う。Viewerは読取のみ。

Headerとaccountsは同じBetter Authセッション、招待、脱退、Team管理APIを使う。Headerの保護要求には検証済みproxy identityを必須とし、Cookieのuserとの不一致を拒否する。GoogleログインとOAuth providerはaccounts限定。DesktopとMCPの認証方式は変えない。

Personal Organizationは本人1名のowner membership、Personal Workspace1件、本人へのdirect Admin1件だけを持つ。名前・slug以外のOrganization属性、共有、招待、Team、追加Workspace、所属解除、削除を拒否する。信頼済みHeaderと確認済みGoogleメールでは、ドメインの参加方式に従ってTeamへ参加する。初回登録時の自動参加と既存ユーザーの本人操作を分離し、再ログインだけでは再追加しない。詳細は下記の2026-09-14の判断に従う。

検索候補は同じOrganizationに所属するユーザー・組織・Teamとする。他Organizationの既知IDにも共有可能だが、共通membershipのないprincipalはtypeとopaque IDだけを表示する。Personal Organizationへの付与は禁止する。

permission変更、membership変更、Team／Organization削除は共通のアプリ側検査を同じDB transaction内で実行する。最後のOrganization owner／member、Team member、有効Workspace Adminを失う操作はrollbackする。Team権限には親Organizationの現在membershipも必要。Team作成者のmembershipも同じtransactionで確定する。アカウント削除は自己削除・管理者削除とも禁止する。

招待はverified login emailとの一致を要求し、既定48時間で失効する。招待URLをコピーして共有し、外部mail serviceは追加しない。

## Organization governance

Organization owner/adminは配下WorkspaceのID・名前・revision・creator IDだけを取得できる。Workspaceへのread permissionにはならず、Server管理者roleだけでも利用できない。暗号化名は用途を限定して復号し、平文を重複保存しない。

Team Organization配下のWorkspaceは確認付きで強制削除できる。確認時のrevisionとWorkspace変更cursorを再検査し、変更があれば409で再確認させる。既存のstorage cleanup、同期通知、操作者付きreceiptを再利用する。Organization削除には配下Workspaceが0件であることも必要。

## Server 管理者

`auth.user.role` の `admin` とBetter Auth admin pluginを使う。初期管理者のbootstrapは既存の方針を維持する。Server管理者はユーザー・組織ディレクトリとServer設定を管理し、この権限だけではWorkspace本文・共有設定・governanceにアクセスできない。

impersonation sessionはread-only。OAuth consent referenceと署名token claimにも引き継ぎ、Gateway / MCP mutationを拒否する。広範な運用で必要になるquotaは今回の対象外。

## Organizationの参加方式と作成・削除（2026-09-14）

ユーザー承認により、Headerだけを対象とする自動参加設定を、Headerと確認済みGoogleメールの参加方式へ拡張する。初回登録ではPersonalを必ず作成し、同じメールドメインが一致するすべての`auto_join`組織にmemberとして追加する。既存ユーザーは再ログインや設定変更だけでは追加しない。

`organization_domains`は組織とドメインの複合主キーを持ち、同一ドメインを複数組織に登録できる。上限は1組織10件。ドメインは正規化した完全一致とし、固定したMITライセンスの共有メールサービス一覧にあるドメインとそのサブドメインは拒否する。owner/adminの設定を信頼し、DNS検証は追加しない。

| 参加方式 | 一致する未所属者の操作 |
| --- | --- |
| `invite_only`（設定の既定値） | 候補には出さず、有効な招待で参加 |
| `need_approval` | 本人が申請し、owner/adminが承認 |
| `auto_join` | 初回登録で自動参加。既存ユーザーは本人が参加を実行 |

自主退会・除名後も現在の方式を適用する。別の参加禁止テーブルは作らない。候補では組織名・ロゴ・本人の申請状態だけを公開し、所属前にメンバーやWorkspaceを公開しない。所属によってWorkspace権限を暗黙に付与しない。

`organization_join_requests`はpending / approved / rejected / cancelledの履歴を保持し、同一ユーザー・組織のpendingは1件に制限する。本人は取り消し、owner/adminは承認・却下できる。却下・取り消し後の再申請を許可する。設定変更で承認制の対象外になったpendingは取り消し、既存所属は維持する。承認とmember追加は同じ認可トランザクション内で確定する。招待承認もこのロックを使い、既存所属を再利用して強い役割を維持し、招待されたTeamを適用する。

Team Organizationの作成・削除はServer管理者のみとする。作成者の認証identityと指定する初期ownerは別に扱い、管理者自身は指定されなければ所属しない。一般のBetter Auth作成・削除経路は無効化し、公開管理APIから共通OrganizationStoreを呼ぶ。Personalは内部のサインアップ初期化のみで作成し、管理者でも削除できない。権限・種別・依存関係は操作直前の認可トランザクション内で確認し、impersonationからの変更を拒否する。配下Workspaceが残る組織と、共有先principalの削除で最後の有効Workspace管理者が失われる組織は削除しない。

Webの削除はServer管理画面に置き、Web/Desktopの作成では初期ownerを明示的に選択する。将来の課金連携も同じServer側作成処理を使うが、今回の範囲に課金、Webhook、専用トークン、DNS、SSO/SCIM、通知メール、ゲスト・期限付き所属を含めない。pendingは画面内で表示する。
