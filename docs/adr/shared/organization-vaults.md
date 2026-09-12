# Organization ownership and Vault roles

2026-09-12。ユーザー承認済み。Server / Web / 未公開 Desktop を同時に変更し、個人所有・read-only共有の決定を置き換える。

## 決定

Server Vault は変更不能な Organization に所属する。Organization membership は内容へのアクセスを与えず、明示した user / organization / team permission だけを評価する。Vault role は `admin | editor | viewer`、有効 role はこの順に強いものを採用する。Admin は内容と Vault 自体・共有を管理し、Editor は内容の作成・更新・削除、録音、AI 処理、Local データの取り込みを行う。Viewer は read-only。Vault の reset / 削除 / Server 間全内容移管は Admin のみ。

これは T5 の Server-account 境界内での共同編集を許可する変更である。録音と確定文字起こしの保全、Local Account の独立性、MCP の read-only 契約、CRM を持たない T2 は変更しない。認証用 Organization は CRM の企業データではない。競合は revision / transaction / 明示的解決を使い、共同編集のために last-write-wins や自動統合へ変更しない。

Better Auth の Organization role `owner | admin | member` と Vault role は独立する。Header と accounts は Web の Better Auth セッション・Organization API を共用し、認証入口だけを変える。Header mode は全保護要求で検証済み proxy identity を要求し、cookie のみの認証や別 user の cookie を認めない。OAuth / Desktop / MCP の認証方式は維持する。

## Organization

`kind = personal | team` は不変。各 user の Personal Organization は `personal-{internal user UUID}` の不変 slug、初期名 Personal、本人の owner membership と Personal Vault / direct admin permission を1組だけ持つ。名前は変更できるが共有・招待・Team・追加 Vault・削除はできない。OAuth の `personal:<userId>` workspace claim は別概念である。

Header 認証は `DAHLIA_AUTH_HEADER`（既定 `X-Forwarded-Email`、例 `Cf-Access-Authenticated-User-Email`）で指定した1つの検証済みメールヘッダーだけを識別に使う。前後空白除去・小文字化・メール検証を API / Better Auth で共用し、`account.account_id` に保存する。`X-Forwarded-User` や他ヘッダーへ fallback しない。内部 user ID は UUID、メール変更は別 identity とし自動統合しない。proxy の上書きと直接接続遮断が前提。

Header の初回 user 登録時だけ、メールドメインと Organization の nullable / unique カスタムフィールド `domain` の完全一致で lookup し、なければ Team Organization を作る。表示名はドメイン、slug は UUID ベース。最初は owner、以後は member。domain は client 入力不可・変更不可。手動作成と Personal の domain は null。サブドメインと一般メールサービスも同じ規則を使う。Google は Personal 作成のみ。退会・除名後は再追加しない。ドメイン組織は通常 Team と同じ制約で削除でき、その後の新規登録時に再作成する。旧 Default 組織と有効化 flag は廃止する。

各 Vault に最低1人の有効 Admin を残す。permission / membership / Team / Organization の変更を原子的に検証する。Team 経由の権限には親 Organization の現在 membership も要求する。最後の Organization owner / member、Team member の解除を拒否する。

同一 Organization の principal は名前・email を検索できる。他 Organization の既知 ID への直接付与は許可するが、共有 membership がなければ type と opaque ID だけを表示する。Personal Organization は共有先にしない。

Organization owner/admin の governance は配下 Vault の ID / name / revision / creator ID と明示的な強制削除に限定し、内容を開示しない。削除確認後の変更は revision と変更 cursor で検出する。Server administrator は自動的に内容・governance 権限を得ない。

`created_by { id, name, email }` は作成時の不変な監査 snapshot。profile 変更で更新せず、Vault 削除まで保持する。通常 API や検索には出さず、governance では creator ID だけを返す。account 削除 cleanup は未実装のため、自己削除・管理者削除とも拒否する。

## 同期と移行

同期台帳と search projection job、暗号鍵の identity は Vault 単位。receipt の user は操作者、summary / image job の user は requester であり、所有者ではない。provider 呼出前と commit 直前に現在の内容書込権限を確認する。差分90日保持、snapshot 復旧、SSE の通知専用性、receipt と pull cursor の分離は維持する。

Local から既存 Server Vault への merge はバックアップ・ID 衝突検査後、所属変更と通常の送信 operation を1つの SQLite transaction で記録する。Server transfer の relocation primitive を再利用する。録音・本文・画像・参照を維持し、元 Vault とその設定 / instructions を残す。確定後の編集は通常 queue へ追加し、移行時に固定した operation / blob の完了を追跡して再起動後も再開する。409 や失効時は未送信データを保持し、Server の部分確定を自動 rollback しない。

インポート中に会議を明示削除する場合、Project 階層の削除も含め、録音 archive が残っている間に削除 operation を記録する。不要になった録音 upload を削除 operation に置き換え、その receipt で固定したインポート完了集合を完了させる。

## 配布境界

Server は未リリース。Desktop は v0.21.0 / DB v41 までが公開済み。Server baseline と Desktop v42 以降を最終形へ再生成・統合し、v41 以前と公開済み backup の復元を維持する。未公開 DB への互換移行や旧 role alias は提供せず、稼働 DB を自動消去しない。新同期契約は capability 5 / transaction schema 3。D1 はサポート対象から外す。D1 の batch は原子的だが、アプリ側の判断を挟む対話的 transaction を Better Auth と共有できず、専用実装の保守を避けるため。Workers は PostgreSQL / Hyperdrive を維持する。

公開版v41の `accountConnectionId` はAI利用先の設定で、Server Vaultの所属ではない。v42ではアカウント接続レコードとVaultのAI設定を保持し、Vaultの接続をnilにする。Organizationを推測せずLocalとして移行し、Serverへの関連付けは移行画面で明示的に行う。Server VaultはorganizationId必須、Local VaultはnilをSQLite CHECKでも検証する。
