# ADR-0029: 任意の Codex AI Gateway を提供する

## Status

Accepted

## Date

2026-08-12

## Context

Dahlia は固定版の Codex app-server を同梱し、AI 要約とアプリ内チャットを録音・文字起こしから分離された付加機能として提供している。現在の接続先は ChatGPT Subscription または、利用者自身の Databricks CLI profile と短期 token を使う Databricks AI Gateway である。

セルフホスト環境では、AI provider の credential と公開モデルをデプロイ管理者が一元管理し、一般利用者には provider secret を配布せずに内蔵 Codex を使わせたい。実行環境として通常のコンテナ、Databricks Apps、Cloudflare Workers を想定する。Dahlia が個別 provider の認証と差異を macOS の機能ごとに実装すると、ADR-0003 が避けた provider 固有処理の重複を再導入する。

一方、Dahlia の中核はローカル完結であり、PRODUCT T4 は外部サービスごとの業務統合を Dahlia に増やさず、T5 は録音・文字起こし・閲覧・検索をネットワークやアカウントへ依存させないことを求める。この判断は、チーム共有、共同編集、顧客データ同期、クラウドでの音声処理や保管へ scope を広げてはならない。

## Decision

固定版の Dahlia 内蔵 Codex から利用する、任意の認証付き AI Gateway を別 runtime として提供する。macOS アプリはリポジトリルートに残し、Gateway は pnpm workspace の独立した TypeScript package `apps/server` に置く。公開サイトは `apps/site` に置き、この配置のために macOS package を移動しない。

Gateway は次の境界を持つ。

- `GET /api/v1/models` と `POST /api/v1/responses` のみを Codex 向け OpenAI Responses 互換 API として公開する。Better Auth の endpoint は `/api/auth/**` に分離する。
- Chat Completions、汎用 Codex client、利用者 API key、`/responses/compact`、自動 provider fallback は提供しない。
- 公開 Model Alias は application database に保存し、単一の OpenAI Responses 互換 upstream に対する model ID へ対応付ける。`default` は特別扱いせず、自動作成しない。
- provider credential と接続先はデプロイ環境だけで変更する。管理者は `/admin/models` で公開 alias、表示名、upstream model、有効状態を管理する。provider secret は API や UI に公開しない。
- `DAHLIA_ADMIN_EMAIL` と database の administrator email を platform administrator とし、`/admin/members` で追加 administrator を管理する。これは Gateway の運用権限だけであり、Organization membership や一般利用者の名簿ではない。
- MVP の tenant は利用者ごとの Personal workspace だけとする。Organization、招待、メンバー、組織権限、組織別 provider は採用せず、必要になった場合は PRODUCT の scope を見直す別 ADR を先に作る。

認証は配置環境ごとに次のいずれか一つを起動時に選ぶ。

- Better Auth mode は Google sign-in を使い、固定 public client に authorization code + S256 PKCE、短期 access token、rotating refresh token、revocation を提供する。動的 client registration は行わない。client ID は ADR-0051 で `databricks-cli` に更新した。
- OAuth scopeはOpenAI互換の`api.model.read`と`api.model.request`を公開し、model listingとResponses requestでそれぞれ必要なscopeだけを検証する。
- Trusted proxy mode は、直接到達できない `/api/**` で proxy が上書きした user ID と email header だけを受理する。Databricks Apps では Dahlia が Databricks U2M token で `/api/v1` を呼び、Apps proxy の検証後に付与される `X-Forwarded-User` と `X-Forwarded-Email` を identity とする。
- `X-Forwarded-Access-Token` は保存せず、AI provider へ転送しない。上流はデプロイ管理者が設定した`OPENAI_API_KEY`をBearer credentialとして呼び出し、`OPENAI_BASE_URL`未指定時はOpenAI APIを使う。

認証と identity を扱う endpoint は Databricks Apps の path contract に合わせて `/api/**` に集約する。ただし Better Auth の sign-in、authorize、token、callback は認証を開始・完了する公開 protocol endpoint であり、アプリのログイン済み session を前提にしない。`/healthz` は機密情報を返さない process liveness に限定し、Databricks Apps の外部無認証 endpoint であることは保証しない。

### データ境界

- provider credential と接続先は全runtime共通の`OPENAI_API_KEY`と`OPENAI_BASE_URL`だけから読み取る。provider未設定でも認証・管理UIは起動し、model listingは空、Responsesは明示的に失敗する。公開 alias、upstream model、有効状態、platform administrator email は認証 metadata と同じ application database に保存する。provider secret を database に保存しないため `DAHLIA_ENCRYPTION_KEY` は持たない。
- Personal workspace ID は認証済み user ID から決定的に導出し、永続化しない。
- Better Auth に必要な user、session、OAuth token metadata と Gateway の Model Alias、platform administrator を、ローカル Node の SQLite、任意の Node 配置または Databricks Lakebase の PostgreSQL、Cloudflare D1 に保存する。trusted proxy mode でも Gateway 管理 metadata のため store を持つ。
- auth store の dialect ごとに明示的な migration を管理する。

Gateway は Codex Responses request と response を中継するため、要約対象の文字起こし、prompt、画像、tool definition や tool output を request 中に扱い、設定された upstream provider へ転送し得る。これらを auth store、cache、analytics、application log、error report に保存しない。raw 録音音声、Dahlia の SQLite database、Vault の同期・backup・upload API は提供しない。利用者向け説明では、AI 利用時に request content が選択された provider へ送信されることと、録音・文字起こしのローカル正本は変わらないことを区別して示す。

Gateway、認証、provider の障害は AI 操作だけを失敗させる。録音開始、音声保存、文字起こし、閲覧、検索、アプリ起動を待たせず、既存のローカル動作へ fallback やデータ変更を発生させない。

## Product Tenet Alignment

- T3: Gateway は録音 critical path に入らず、音声保存や確定文字起こしの永続化を待たせない。
- T4: Gateway は CRM 等を操作する業務統合ではなく、ADR-0003 が所有する内蔵 Codex の model-provider transport である。外部サービスのデータ同期、tool、workflow は追加しない。
- T5: Codex による要約生成は既存の許容された外部依存であり、Gateway はその任意の接続方法に留まる。未設定、未認証、停止中でも中核機能は動作する。
- Out of scope: Personal workspace は AI 利用 identity の分離だけに使い、meeting、transcript、Vault、Organization、Contact の共有や権限管理には使わない。

この ADR は product tenet を変更しない。2026-08-13 のリリース前レビューで Model Alias と platform administrator の database 管理を追加し、既存本文を直接更新することについてユーザー承認を得た。macOS の接続変更は引き続き別の判断とする。

## Consequences

良い影響:

- 一般利用者へ provider secret を配布せず、デプロイ管理者が再起動なしで利用可能モデルを一元管理できる。
- 内蔵 Codex は Responses interface に固定され、macOS の機能ごとに provider adapter を持たずに済む。
- 各 deployment が同じ application contract を共有し、認証 metadata だけを各 runtime に適した store へ配置できる。
- AI service の停止や認証失敗が録音・文字起こしの正本へ影響しない。

トレードオフ:

- AI 操作は Gateway、認証基盤、upstream provider の可用性に依存する。
- AI 利用時の request content は Gateway と upstream provider を通るため、ローカルだけで処理されるとは表示できない。
- 選択した application store を backup し、provider credential はデプロイ先の secret store で安全に運用する必要がある。
- Model listing と Responses request は Model Alias を解決する application database の可用性に依存する。Databricks trusted proxy mode でも Lakebase が必要になる。
- server-only MVP だけでは Dahlia の設定画面から接続できない。最初は固定 Codex と手動 `config.toml` で contract を検証し、製品統合は別の macOS 変更として行う。
- runtime固有処理は認証とstorageに限定し、upstream transportは単一のcontract testで検証する。

## Alternatives Considered

### provider credential を各利用者へ配布する

却下。一般利用者が backend secret を保管する必要があり、失効、rotation、公開モデル制御を管理者が一元化できない。

### Gateway に録音、文字起こし、会議データを保存する

却下。クラウドを meeting data の正本または同期先にし、T3、T5 と現在の out-of-scope を変更する。AI request の一時的な中継に必要な範囲を超える。

### Organization とメンバー権限を MVP に含める

却下。チーム共有と権限管理は現在の PRODUCT で out of scope である。Personal workspace で AI identity を分離し、組織機能は必要性と product scope を別 ADR で判断する。

### macOS package を `apps/macos` へ移動してから追加する

却下。Gateway は独立 package として追加でき、既存 SwiftPM path、build、release tooling を再配置する必要がない。

### macOS 統合と Gateway を同時に実装する

却下。まず server contract と固定版 Codex の互換性を手動設定で検証し、認証情報の保持、UI、config 切り替えを伴う macOS 変更は独立してレビューする。

## Relationship

承認された場合、ADR-0003 の model provider と認証の選択肢を追加する。共有 Codex app-server、固定 binary、専用 `CODEX_HOME`、録音から分離された AI runtime という既存判断は置き換えない。Databricks CLI の user `HOME` 継承を定める ADR-0021 も変更しない。

## References

- [`PRODUCT.md`](../../PRODUCT.md): T3、T4、T5、Out of scope
- [ADR-0003](0003-use-a-shared-codex-app-server.md): 固定版 Codex app-server と provider ownership
- [ADR-0021](0021-preserve-user-home-for-databricks-authentication.md): Databricks CLI authentication
- [OpenAI Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [`CodexConfigurationManager`](../../apps/desktop/Sources/Dahlia/Services/CodexConfigurationManager.swift)
