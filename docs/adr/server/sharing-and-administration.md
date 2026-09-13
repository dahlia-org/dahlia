# Workspace 共有と管理者

対象: Server / Private Web。2026-09-12の[Organization所有・共同編集](../shared/organization-vaults.md)により更新。

## 共有境界

Workspaceは変更不能なOrganizationに所属する。Organization所属だけでは内容へのアクセスを与えず、`workspace_permissions` のuser / organization / team principalに `admin | editor | viewer` を付与する。有効roleはAdmin、Editor、Viewerの順で解決する。AdminはWorkspace設定・共有・reset・削除・全内容移管を行い、AdminとEditorは内容の作成・変更・削除・録音・AI処理を行う。Viewerは読取のみ。

Headerとaccountsは同じBetter Authセッション、招待、脱退、Team管理APIを使う。Headerの保護要求には検証済みproxy identityを必須とし、Cookieのuserとの不一致を拒否する。GoogleログインとOAuth providerはaccounts限定。DesktopとMCPの認証方式は変えない。

Personal Organizationは本人1名のowner membership、Personal Workspace1件、本人へのdirect Admin1件だけを持つ。名前以外のOrganization属性、共有、招待、Team、追加Workspace、所属解除、削除を拒否する。Header認証では設定されたメールヘッダーのドメインに対応するOrganizationへ初回登録時だけ参加し、なければ作成する。脱退・除名後の再追加は行わず、ドメイン組織の削除は通常Teamと同じ制約に従う。Google認証はPersonalのみ自動作成する。

検索候補は同じOrganizationに所属するユーザー・組織・Teamとする。他Organizationの既知IDにも共有可能だが、共通membershipのないprincipalはtypeとopaque IDだけを表示する。Personal Organizationへの付与は禁止する。

permission変更、membership変更、Team／Organization削除は共通のアプリ側検査を同じDB transaction内で実行する。最後のOrganization owner／member、Team member、有効Workspace Adminを失う操作はrollbackする。Team権限には親Organizationの現在membershipも必要。Team作成者のmembershipも同じtransactionで確定する。アカウント削除は自己削除・管理者削除とも禁止する。

招待はverified login emailとの一致を要求し、既定48時間で失効する。招待URLをコピーして共有し、外部mail serviceは追加しない。

## Organization governance

Organization owner/adminは配下WorkspaceのID・名前・revision・creator IDだけを取得できる。Workspaceへのread permissionにはならず、Server管理者roleだけでも利用できない。暗号化名は用途を限定して復号し、平文を重複保存しない。

Team Organization配下のWorkspaceは確認付きで強制削除できる。確認時のrevisionとWorkspace変更cursorを再検査し、変更があれば409で再確認させる。既存のstorage cleanup、同期通知、操作者付きreceiptを再利用する。Organization削除には配下Workspaceが0件であることも必要。

## Server 管理者

`auth.user.role` の `admin` とBetter Auth admin pluginを使う。初期管理者のbootstrapは既存の方針を維持する。Server管理者はユーザー・組織ディレクトリとServer設定を管理し、この権限だけではWorkspace本文・共有設定・governanceにアクセスできない。

impersonation sessionはread-only。OAuth consent referenceと署名token claimにも引き継ぎ、Gateway / MCP mutationを拒否する。広範な運用で必要になるquotaは今回の対象外。
