# ADR-0030: 任意の個人課金と将来の Team schema を追加する

- Status: Accepted
- Date: 2026-08-13

## Context

Dahlia Cloud の AI Gateway をマネージドサービスとして提供するには、個人利用者向けの月額課金と利用権の管理が必要になる。一方、セルフホスト環境では Stripe を必須にせず、認証済み利用者が従来どおり Gateway を利用できる必要がある。

認証後の画面には現在、モデル一覧と OAuth session 管理が直接配置されている。課金を追加するにあたり、利用者自身の情報、請求、session 管理を一貫した Dashboard 配下へ整理する。

将来は Organization 単位の seat 課金を提供する可能性がある。ただし、現時点の [PRODUCT.md](../../PRODUCT.md) はチーム共有、共同編集、権限管理を対象外としており、[ADR-0029](0029-offer-an-optional-codex-ai-gateway.md) も Personal workspace のみを認めている。Organization、招待、membership を実行時に有効化することは今回の判断に含めない。後から認証 schema を破壊的に変更せずに済むよう、Better Auth 互換の schema だけを予約する。

なお、Cloud の認証・課金で用いる `organization` は、Dahlia macOS アプリがローカルに保持する顧客情報の Organization とは別の概念であり、データを共有しない。利用者向け UI では混同を避けるため `Team` と呼ぶ。

## Decision

### Dashboard

- 認証後の入口を `/dashboard` とする。`/` は認証状態に応じて `/dashboard` または `/sign-in` へ遷移する。
- `/dashboard` は利用者の名前、メールアドレス、`Personal account` を表示する Overview とする。
- `/dashboard/settings` に Active Sessions を配置し、既存の OAuth session 一覧と失効操作を維持する。
- `/dashboard/billing` は Stripe 課金が有効な場合だけ navigation と route を有効にする。
- ブラウザー向けモデル一覧 UI と `/api/models` は削除する。Codex 向け `/api/v1/models` は維持する。
- UI と `/api/session` は Better Auth、trusted proxy といった実装方式名ではなく、`capabilities.billing` と `capabilities.sessions` で機能の有無を表現する。

### Optional Stripe billing

- Stripe 課金は `DAHLIA_AUTH_PROVIDER=accounts` だけで利用できる任意機能とする。
- `STRIPE_SECRET_KEY`、`STRIPE_WEBHOOK_SECRET`、`STRIPE_PRO_MONTHLY_PRICE_ID` の三つを必須設定の一組とする。
  - すべて未指定なら課金を無効化する。課金 API、route、navigation、Gateway の課金判定を登録しない。
  - 一部だけ指定されている場合は設定不備として起動を失敗させる。
  - `header` 認証で指定されている場合も起動を失敗させる。
- Better Auth の公式 Stripe plugin と Stripe SDK を用い、Customer 作成、Checkout、subscription 同期、署名付き webhook、Customer Portal を提供する。
- MVP の商品は個人向け Free と Pro の月額プランだけとする。年額、従量課金、on-demand usage、Team seat 課金は提供しない。
- subscription の `referenceId` はログイン中の User ID に固定し、別 User ID や Organization ID を指定する操作を拒否する。
- `GET /api/billing/summary` は Stripe ID を公開せず、現在のプランと状態、月額と通貨、更新日または終了予定日、支払管理の可否、最新十二件の請求書を正規化して返す。
- 支払方法、解約、請求書管理は Stripe Customer Portal に委ねる。請求書一覧は Stripe から取得し、Dahlia のデータベースには複製しない。
- Stripe に送るのは課金に必要な顧客・subscription 情報だけとし、録音、音声、文字起こし、プロンプト、生成内容、利用量を送信しない。

### Gateway entitlement

- Stripe 課金が有効な場合、`active` または `trialing` の Pro subscription を持つ個人利用者だけが `/api/v1/models` と `/api/v1/responses` を利用できる。
- Free、`past_due`、`canceled`、その他の状態では両 endpoint が `402 billing_required` を返す。
- 利用権は署名検証済み webhook の subscription snapshot とイベント世代を一組として、Better Auth store 内の Dahlia 管理の entitlement projection へ同期する。イベント順序を条件にした原子的更新により、古いイベントや同じイベントの再配送が新しい停止状態を上書きできないようにする。
- Gateway はこの検証済み projection をリクエストごとに確認し、hot path から Stripe API を呼ばない。Better Auth plugin の subscription 行は Checkout・Portal・Customer の連携に用いるが、Gateway 認可の source of truth にはしない。
- Stripe 課金が無効なセルフホスト環境では、認証済み利用者が従来どおり Gateway を利用できる。

### Future Team schema

- SQLite、PostgreSQL、Cloudflare D1 の Better Auth migration に、Stripe subscription、検証済み entitlement projection、将来用の `organization`、`member`、`invitation` schema を追加する。
- Organization には将来の Organization Stripe Customer を保持できる nullable な列を用意する。
- `member.userId` に global unique constraint を付け、一人の User が所属できる Organization を最大一つに制限する。未所属の個人利用は引き続き認める。
- Better Auth Organization plugin は schema 生成時だけ参照し、runtime には登録しない。Team 作成、招待、参加、membership 管理 endpoint と UI は提供しない。
- Better Auth の入れ子の `team` / `teamMember` 機能は使用しない。将来の利用者向け `Team` は内部の `organization` と一対一に対応させる。
- Team への参加時に個人 subscription を終了し、Organization subscription へ移行する専用フローは、seat 課金を導入する将来の ADR で決定する。按分、返金、seat 同期も今回の対象外とする。

## Product alignment

- 課金対象は録音・文字起こしに必須ではない、疎結合な AI Gateway だけである。録音、文字起こし、ローカルデータの所有権や保存先は変更しない。
- Dashboard と課金は既存 Codex 要約経路の接続先を提供するための付加機能であり、Dahlia をクラウド常時接続前提の製品にはしない。
- Organization schema の予約は Team 機能を有効化しない。チーム共有、共同編集、権限管理は引き続き対象外である。
- Cloud の `organization` と macOS のローカルな顧客 Organization は独立しており、相互同期もクラウド保存も行わない。

## Consequences

- マネージド環境は Stripe webhook に同期された状態だけで Gateway 利用権を高速に判断できる。
- セルフホスト利用者は Stripe を設定せずに認証と Gateway を利用でき、不要な課金 UI や endpoint も露出しない。
- Checkout、subscription lifecycle、Portal、webhook 署名検証は公式連携へ委ねる。Dahlia が追加で保持するのは、Gateway を fail-closed に保つための順序付き entitlement projection に限定する。
- 請求書一覧の表示時には Stripe API への到達が必要になるが、Gateway の推論経路には影響しない。
- 将来の Team 導入時に schema の土台を再利用できる一方、実際の Team lifecycle と seat 課金には別の ADR と実装が必要になる。
- `member.userId` の global unique constraint により、将来複数 Organization への所属を許可する場合は明示的な schema 変更が必要になる。

## Alternatives considered

### Stripe をすべての配置で必須にする

セルフホストの導入負担を増やし、任意のクラウド付加機能という位置付けに反するため採用しない。

### Stripe SDK だけで subscription lifecycle を独自実装する

Better Auth の User と subscription の同期、webhook、Customer Portal 連携を重複実装することになるため採用しない。

### Organization plugin と Team UI を今回から有効化する

Personal workspace に限定した ADR-0029 と PRODUCT.md の範囲を越え、招待、権限、seat lifecycle を同時に確定する必要があるため採用しない。

### 従量課金または年額プランを同時に導入する

利用量の計測・価格・請求補正を追加し、MVP の課金状態を不必要に複雑化するため採用しない。

### 個人 subscription と Organization subscription の共存を許可する

課金主体と利用権が曖昧になり、返金・按分・seat 同期の競合を生むため採用しない。将来の Team 参加は専用の移行フローを前提とする。

## Relationship to prior decisions

この ADR は ADR-0029 の Personal-only 境界を「実行時は Personal-only のまま、将来用 Organization schema の予約を許す」と限定的に補足し、任意の個人課金を追加する。Organization、招待、membership、seat 課金を提供する判断は含まない。

この判断に基づき、Dashboard、Stripe、subscription、Organization schema を実装する。

## References

- [PRODUCT.md](../../PRODUCT.md)
- [ADR-0029: 録音・文字起こしから疎結合な任意の Codex AI Gateway を提供する](0029-offer-an-optional-codex-ai-gateway.md)
- [Better Auth Stripe plugin](https://better-auth.com/docs/beta/plugins/stripe)
- [Better Auth Organization plugin](https://better-auth.com/docs/beta/plugins/organization)
- [Stripe Customer Portal](https://docs.stripe.com/customer-management)
