# Organization と Workspace の所有・役割・本人用 Workspace

- 採択: 2026-09-12（Organization 所有と Workspace role）。
- 本人用 Workspace と登録時の Organization 作成は 2026-09-21 にユーザーが承認した。

## 決定

Server Workspace は変更不能な Organization に所属する。Organization の kind は持たない。Workspace は nullable な `personal_user_id` を持ち、NULL は通常 Workspace、user UUID はその本人専用 Workspace を示す。`organization_id` と `personal_user_id` の一意制約で、各 Organization・本人につき1件とする。所有は Organization、本人は専用領域の利用者である。

Organization membership は内容へのアクセスを与えない。明示した user / organization / team permission だけを評価する。Workspace role は `admin | editor | viewer` で、有効 role はこの順に強いものを採用する。Admin は内容と Workspace 自体・共有を管理する。Editor は内容の作成・更新・削除、録音、AI 処理、Local データの取り込みを行う。Viewer は read-only である。Workspace の reset・削除・Server 間の全内容移管は Admin のみ行う。

Better Auth の Organization role `owner | admin | member` と Workspace role は独立する。Header と accounts は Web の Better Auth セッション・Organization API を共用し、認証入口だけを変える。Header mode は全保護要求で検証済み proxy identity を要求し、cookie のみの認証や別 user の cookie を認めない。OAuth / Desktop / MCP の認証方式は維持する。

この決定は T5 の Server-account 境界内での共同編集を許可する。録音と確定文字起こしの保全、Local Account の独立性、MCP の read-only 契約、CRM を持たない T2 は維持する。認証用 Organization は CRM の企業データではない。競合は revision / transaction / 明示的解決を使い、共同編集のために last-write-wins や自動統合へ変えない。

## 認証と identity

Header 認証は `DAHLIA_AUTH_HEADER`（既定 `X-Forwarded-Email`、例 `Cf-Access-Authenticated-User-Email`）で指定した1つの検証済みメールヘッダーだけを識別に使う。前後空白除去・小文字化・メール検証を API / Better Auth で共用し、`account.account_id` に保存する。`X-Forwarded-User` や他のヘッダーへ fallback しない。内部 user ID は UUID である。メール変更は別 identity とし、自動統合しない。proxy の上書きと直接接続の遮断が前提である。OAuth の `personal:<userId>` workspace claim は別概念である。

## Organization

同一 Organization の principal は名前・email を検索できる。他 Organization の既知 ID への直接付与は許可するが、共有 membership がなければ type と opaque ID だけを表示する。

各 Workspace に最低1人の有効 Admin を残す。permission / membership / Team / Organization の変更を原子的に検証する。Team 経由の権限には親 Organization の現在 membership も要求する。最後の Organization owner / member と、Team member の解除を拒否する。

Organization owner/admin の governance は、配下 Workspace の ID / name / revision / creator ID と明示的な強制削除に限定し、内容を開示しない。削除確認後の変更は revision と変更 cursor で検出する。Server administrator は自動的に内容・governance 権限を得ない。

`created_by { id, name, email }` は作成時の不変な監査 snapshot である。profile 変更で更新せず、Workspace 削除まで保持する。通常 API や検索には出さず、governance では creator ID だけを返す。

Organization の名前と slug は既存の更新 API で変更できる。手動入力の slug は `[a-z0-9_-]+` とし、重複は拒否する。`personal-` で始まる slug は予約する。組織の URL は `/orgs/{organizationId}` を使うため、slug の変更では変わらない。slug の変更は ID、ドメイン設定、所属に影響しない。Organization の作成は Server 管理者に限定し、Desktop の取り込み画面では既存 Organization の選択だけを行う。local single-user モードで元の文字列が空の場合は `organization` を初期値とする。自動作成 slug が既存 Organization と重複する場合は `_2`、`_3` の順で空いている値を認可 transaction 内で採番する。

ドメイン設定、初回登録時の自動参加と本人操作による参加・再参加は [Organization の参加方式](../server/sharing-and-administration.md#organizationの参加方式と作成削除2026-09-14) に従う。ドメイン設定の削除は所属を削除しない。

## 本人用 Workspace

本人用の通常アクセスは、本人かつ現在の Organization メンバーに限る。API、SQLite predicate、PostgreSQL RLS で強制する。Organization 管理者・Server 管理者というだけでは内容にアクセスできない。通常 Workspace の外部 direct 共有は許可する。

本人用 Workspace の共有・通常削除・種別変更は禁止する。脱退時は内容と ID を保持してアクセスを失効し、再参加で同じ ID を利用する。既存の Organization governance による確認付き強制削除は維持する。削除した ID や内容の復活は保証しない。

組織参加と本人用 Workspace・本人への direct admin 権限の作成は、同じ DB transaction で確定する。招待承認、参加申請承認、ドメイン自動参加、管理者による追加、初期 owner 登録で共通処理を使う。再試行は既存 ID を保持し、設定や内容を上書きしない。失敗時は参加も rollback する。

## サインアップとデプロイ

`DAHLIA_AUTO_CREATE_ORG_ON_SIGNUP` は未指定または 0 で無効、1 で有効とする。それ以外の値は設定エラーである。無効時は管理者が Organization を作成し、未所属ユーザーは参加または招待を待つ。最初の Server 管理者は組織管理画面から作成できる。

有効時は、新規登録の初期化で通常 Organization を1件作成し、本人を owner にして本人用 Workspace を作る。Organization 名は表示名に「のOrg」を付け、空なら My Organization とする。slug は既存の正規化・衝突回避を使う。既存のドメイン自動参加も行い、各参加先に本人用 Workspace を作る。登録完了と Organization 作成は同じ transaction に含める。完了済みユーザーの再ログイン・設定変更では Organization を作らず、未完了の再試行はその時点の設定を使う。

自動作成は配置方針であり、Organization の種別ではない。課金・プラン・制限は既存 Organization に紐づけて設計する。一般ユーザーが追加の Organization を作成する API は持たない。

## UIと互換性

Server のサイドバー上部で Organization を選び、本人用とアクセス可能な通常 Workspace を表示する。各 Workspace の内容は展開時に取得する。未所属 Organization からの共有は別に表示する。検索は Workspace 単位で行い、チャットの所有は変更しない。Desktop は Server の Workspace を表示しない。

## 同期と移行

同期台帳と search projection job、暗号鍵の identity は Workspace 単位とする。receipt の user は操作者、summary / image job の user は requester であり、所有者ではない。provider 呼出前と commit 直前に現在の内容書込権限を確認する。差分90日保持、snapshot 復旧、SSE の通知専用性、receipt と pull cursor の分離は維持する。

Desktop は Server と同期しない（[同期](sync.md#正本とアカウント境界)）。Desktop の Workspace を Server Workspace へ取り込む経路と、Server Workspace へ再接続する経路は無い。

## 配布境界

公開済み backup の復元を維持する。未公開 DB への互換移行や旧 role alias は提供せず、稼働 DB を自動消去しない。新しい DB に適用し、旧 DB の保持が必要な場合は別途移行する。既存 slug は移行しない。Desktop は v46 で nullable なキャッシュ列を追加し、既存行を保持する。同期契約は [同期](sync.md) に従う。

Server Workspace は organizationId を必須とする。Desktop の Workspace は Organization を持たず、`accountConnectionId` とともに nil であることを SQLite CHECK で検証する（起動時に両方を空にする）。公開版 v41 の `accountConnectionId` は AI 利用先の設定で、Server Workspace の所属ではない。

Server は PostgreSQL / Hyperdrive を使う（Workers を含む）。D1 はサポート対象に含めない。

## 却下した案

- D1 をサポート対象にする: D1 の batch は原子的だが、アプリ側の判断を挟む対話的 transaction を Better Auth と共有できず、専用実装の保守を避けるため。

## 未適合・未検証

- 未実装: Account 削除の cleanup。自己削除と管理者による削除は拒否する。
- 未実装: 課金・プラン・制限（将来は既存 Organization に紐づける）。
- 未確定: Organization の名前・slug を変更できる権限の範囲。kind による区別が廃止された後の権限は、本文に記載がない。
- 未確定: `personal-` の slug 予約を、kind 廃止後も保持する意図か。
- 未確定: Google サインインの登録時の扱い。Personal の作成が廃止されたため、Organization 自動作成の対象になるかは本文から判断できない。
- 未確定: Server の未リリース状態が現在も続くか。
