# Desktop の認証と account 分離

対象: Desktop。採択: 2026-08-04〜09-01。実行場所と AI 設定のスコープは [アカウント別の Desktop 推論](../shared/account-scoped-desktop-inference.md)（採択: 2026-10-02）、実行ランタイムは [内蔵 Pi runtime](pi-runtime.md)（採択: 2026-11-06）に従う。Server Account の移行・サインアウト時のデータ扱いは [同期契約](../shared/sync.md#正本とアカウント境界) に従う。

## 接続と Workspace

Server Account の接続はアプリ共有の接続として SQLite に UUID、正規化 origin、client ID、作成日時を保存する。Cloud は最大1件、Server は複数登録できるが同一 origin は一意。Cloud / Server 種別は現在の Cloud origin との一致から導出し、保存しない。同一 origin の複数 remote account 切替は対象外。

credential と remote identity / 表示情報は接続 UUID ごとの Keychain が所有する。token API は connection ID を必須にし、接続ごとの actor が refresh の集約と rotation の永続化を行う。credential がなければ再サインインを案内し、ローカル機能を妨げない。

サインアウトは remote revocation を試みた後、結果にかかわらず local credential を削除し、失効失敗は通知する。Server の canonical data は削除せず、local working copy の扱いは同期契約に従う。

プロバイダーアカウントは設定の「機能」グループの「プロバイダー」ページで管理する。ChatGPT・Anthropic（Pi がサインインを持つ）、Databricks の接続、以前に追加した workspace、Google を並べ、追加・再サインイン・名前の変更・サインアウト・削除と、各アカウントが提供する capability を示す。「エージェント → モデル」はプロバイダーごとのモデルのオン・オフだけを持ち、アカウントの操作はこのページへ案内する。アプリのアカウントは 1 つで、今の Local Account を引き継ぐ（[単一アカウントへの移行](../../plans/2026-11-23-single-account-provider-accounts.md)）。Databricks の接続はアカウントではなく、そのアカウントが使うプロバイダーアカウントであり、モデル（Gateway）・MCP・カレンダー（Google Calendar の proxy）を提供する。サイドバー下部のアカウントメニューは Databricks の接続を並べず、アカウントを切り替えない。設定の「Dahlia AI」はアカウントの provider と AI 設定を示す。Databricks の接続のサインアウトは設定の「プロバイダー」ページで行い、確認モーダルで対象を示す。確認後にだけ接続を切断し、キャンセル、閉じる、Escape、背景クリックでは切断しない。接続を削除しても、アカウントの履歴と設定は残り、その接続のモデル・MCP・カレンダーだけが使えなくなる。接続が 2 つ以上あるときは、当面最も古い 1 つだけを使う（Pi のプロバイダー ID が `databricks` で共通のため）。

Databricks の接続は複数持て、OAuth の token 処理は接続ごとに独立する。接続は `provider_accounts` テーブル（`kind = 'databricks'`、clientID は `databricks-cli`）に置き、利用者が付けた表示名（`name`、任意）を持てる。再サインインしても表示名は残す。表示名は設定の「プロバイダー」ページで変更し、空にすると workspace とメールアドレスを表示する。プロバイダー一覧、モデルの選択、カレンダーのプロバイダー、サインアウトの確認は表示名で示す。表示名はプロバイダー ID や認証の参照には使わない。0.29 までの UserDefaults の接続と Keychain の credential は起動時に削除して引き継がず、ユーザーには再サインインを案内する（Workspace とデータは Local Account に残る）。カレンダーソースと Google カレンダーの表示カレンダーは開いているアカウントごとに保存し（`enabledCalendarSources.<アカウント>`、`googleCalendarSelectedCalendarIDs.<アカウント>`。未設定のアカウントは従来のアプリ共通の値を引き継ぐ）、会議リンクを開くアプリも開いているアカウントごとにこの Mac へ保存する（未設定のアカウントは直前のアカウントの値を引き継ぐ）。Google カレンダーで前回取得した予定は、起動やアカウント切り替えの直後に取得を待たず表示できるよう、アカウントごとの JSON ファイル（Application Support の `Caches/GoogleCalendar/<アカウント>.json`）に丸ごと置き換えて保存し、切断で削除する。使い捨てのスナップショットなので SQLite には置かない。キャッシュは表示だけに使い、会議に保存した予定情報は新規取得の完了後に更新する。メニューバー表示と予定の絞り込みはアプリ共通とする。参加表明していない予定（仮承諾を含み、辞退済みを除く）と辞退済み予定は独立して表示を選べる。両方とも既定で非表示とし、表示する場合は未参加表明の予定を薄く、辞退済みの予定を薄く取り消し線付きでサイドバー・予定一覧・メニューバーに表示する。設定画面では、カレンダーのプロバイダーと予定の絞り込みを「機能 → カレンダー」の「カレンダーソース」「予定の表示」タブにまとめる。プロバイダー（macOS カレンダー、Google、Databricks の接続）はモデルや MCP と同じく 1 つずつ折り畳んで並べ、行のスイッチでオンにし、中に接続状態と表示するカレンダーを置く。メニューバー表示は「この Mac → 外観」、会議リンクを開くアプリは「機能 → ミーティング」の「会議リンク」タブに置く。セットアップツアーのカレンダー手順は、ツアーで選んだアカウントに保存する。Google カレンダーと Drive のバックアップ読み取りは、利用者が選んだプロバイダーから読む。Google なら直接の Google OAuth、Databricks の接続ならその Unity Catalog connection proxy を使う。Google は 1 つのプロバイダーアカウントで、カレンダーと Drive は 1 つのサインインを共有する。サインインは使い始めるたびにその用途の権限を足し、切断すると両方とも使えなくなる。用途ごとに分けていた以前のサインインは起動時に削除し、再サインインを求める。同じカレンダーを読むので、オンにできるのはどちらか一方で、片方をオンにするともう片方はオフになる。選択は UserDefaults の `googleCalendarProvider` に保存し、未設定か、選んだ接続がもう無いときは、アカウントの Databricks の接続があればそれを、無ければ Google を使う。macOS カレンダーは OS の権限で読み、`provider_accounts` には置かない。proxy の認証には Databricks の Bearer token を使い、Google の credential は接続側が管理する。proxy 経由の JSON 読み取りで Google が 401 を返した場合は一度だけ再試行する。なお失敗する場合は接続ページで既存 credential を取り消して再認証するよう案内し、Databricks 自体の 401/403 や Google の 403 とは区別する。

Workspace はアカウントに属さない。起動時に、すべての Workspace の `workspaces.databricksConnectionId` を空にする。最後に開いていた Workspace が Databricks アカウントのものだった Mac では、その 1 回だけ、そのアカウントの履歴（`accountID` を持つ行）・アカウント別の設定・Pi のファイルを Local へ写す。元のディレクトリと設定のキーは残す。

Workspace を Databricks の接続へ移す操作と、接続ごとの `Default` は無い。アカウントの Workspace が無いときは `Default` を 1 つ作る。サインイン画面と Workspace 選択画面の背景クリックでは離脱せず、キャンセル／閉じるボタンか Escape で明示的に取り消す。キャンセルしても、接続したアカウントは残す。

アカウントメニューのサインインでは、接続済みかどうかにかかわらず URL を入れて Databricks の接続を追加する（接続済みの URL は再認証になる）。サインインの後に Workspace の移動や作成は尋ねず、開いている Workspace は変わらない。セットアップのアカウント選択とアカウントメニューのサインインは、従来のモーダルの形で Databricks workspace への接続と Local Account だけを示し、Server Account のサインインは表示しない（未確定事項を参照）。

モデルプロバイダー設定の provider 一覧には、Local / Databricks アカウントの provider に加え、Server Account 自身の provider（`dahlia`、Server の Gateway）を並べる（[内蔵 Pi runtime](pi-runtime.md) の provider 表）。

## 実行アカウントの context

Workspace の nullable connection ID は nil を Local Account とし、削除時は SET NULL。Local Account は OpenAI / Anthropic の subscription を、Databricks アカウントはその workspace の Gateway を、Server Account はその Server の Gateway を使う。

モデルは開いているアカウントのものだけを使う。設定には、そのアカウントの provider だけを表示する。AI 設定のスコープ、アカウント切替の処理、モデル設定の保存先は [アカウント別の Desktop 推論](../shared/account-scoped-desktop-inference.md) に従う。旧 Vault の summary 列は互換性のため保持するが、新規 summary の設定や実行先判定には使わない。

Pi の agent directory は、アプリのアカウントでは `Application Support/Dahlia/agent` の 1 つ、Dahlia Server のアカウントでは `Application Support/Dahlia/accounts/<provider_accounts.id>/pi` にする。実行アカウントは Local、Databricks 接続（`databricks(connectionID:)`）、Server Account を区別する。切替は Pi の process を閉じ、そのアカウントの `models.json` に workspace の Gateway を書く。録音後の処理の実行先は `databricksWorkspace` キーで保存する。

## ChatGPT と Databricks Workspace OAuth

2026-09-10 に採択。Databricks provider は CLI に依存せず、Desktop が U2M OAuth を実行する。既存 CLI 設定・token cache は参照しない。利用者は Workspace URL を入力し、ブラウザで再サインインする。

public client は `databricks-cli`、scope は `offline_access all-apis` に固定する。redirect URI は `http://localhost:8020` から `8040` のうち待受できた最初のポートを使い、すべて使用中なら失敗を表示する。64 バイトの PKCE verifier と S256、state を使う。Workspace discovery の authorization / token endpoint を検証し、取得不能・不正なら同一 Workspace の `/oidc/v1/authorize` と `/oidc/v1/token` を使う。Server Account の resource / userinfo フローとは分離する。

Databricks 接続は HTTPS Workspace origin と認証境界用 UUID をこの Mac に保存する。同じ Workspace は再認証し、別 Workspace への変更はサインアウト後に行う。従来の `databricksProfile` 設定値は新しい接続の UUID を保持する互換フィールドとして使い、CLI profile 名には解決しない。旧 Vault 列と登録済み migration は保持する。credential は実行環境と接続 ID ごとの Keychain に保存し、refresh rotation の保存失敗では新 token を公開しない。サインアウトは選択接続と local credential を削除し、進行中更新の結果を拒否する。

token は要求ごとに標準入力で渡し、config・環境変数・log には残さない（[内蔵 Pi runtime](pi-runtime.md)）。Databricks の会話 turn 全体を再実行する回復経路は追加しない。

## 制約

接続関連の契約を Server Account の現在のデータ lifecycle へ一般化しない。移行とサインアウト時のデータ扱いは同期契約に従う。

設定画面を開いても、実行アカウントの context・設定ファイル・Server の token 認可は変更しない。

実ユーザーの HOME 継承により `$HOME/.agents/skills` が探索され得る。これは未監査の user skill であり、分離は未検証のまま残す。当面の最終境界は、要約での skill 無効化、MCP の Workspace 検証、[承認方針](chat-approval.md) とする。

## 未適合・未検証

- 未確定: Server Account のサインインの表示。記録では「当面表示しない」とし、接続の削除の導線がないため、サインインを戻すときに足すとする。Databricks をデータの正本にする場合の同期設計は別途行うとする。現在の表示と同期契約（Server Account を前提とする）との関係は未確定。
- 未確定: Gateway の 401 時の強制 refresh と1回の再試行、ブラウザ認証の待受 300 秒、認証コマンドと broker の timeout（360 秒、365 秒、20 秒）、token 更新間隔 25 分、直接 Databricks provider の stream retry を 0 にすること、ChatGPT ログインの request shape は、Codex・auth-helper・token broker の経路の値である。Pi への置換（2026-11-06）後に同じ規則が有効かは [内蔵 Pi runtime](pi-runtime.md) に記載がなく未確定。Pi の bridge が要求元との対応を検証し、認証完了後に認可を再検証するかも未確定。
- 未検証: 実ユーザーの HOME 継承による `$HOME/.agents/skills` の分離。追跡 issue は [dahlia-org/dahlia#234](https://github.com/dahlia-org/dahlia/issues/234)。
