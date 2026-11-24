# Desktop の認証と account 分離

対象: Desktop。採択: 2026-08-04〜09-01。実行場所と AI 設定のスコープは [アカウント別の Desktop 推論](../shared/account-scoped-desktop-inference.md)（採択: 2026-10-02）、実行ランタイムは [内蔵 Pi runtime](pi-runtime.md)（採択: 2026-11-06）に従う。Desktop は Dahlia Server と同期しない（[同期契約](../shared/sync.md#正本とアカウント境界)）。

## 接続と Workspace

Dahlia account（Dahlia Server へのサインイン）の接続はアプリ共有の接続として SQLite に UUID、正規化 origin、client ID、作成日時を保存する。Cloud は最大1件、Server は複数登録できるが同一 origin は一意。Cloud / Server 種別は現在の Cloud origin との一致から導出し、保存しない。同一 origin の複数 remote account 切替は対象外。

credential と remote identity / 表示情報は接続 UUID ごとの Keychain が所有する。token API は connection ID を必須にし、接続ごとの actor が refresh の集約と rotation の永続化を行う。credential がなければ再サインインを案内し、ローカル機能を妨げない。

サインアウトは remote revocation を試みた後、結果にかかわらず local credential を削除し、失効失敗は通知する。Workspace と会議は Server に属さないので、サインインとサインアウトでは変わらない。

プロバイダーアカウントは設定の「機能」グループの「プロバイダー」ページで管理する。追加モーダルではプロバイダーを1列のリストで並べ、ロゴ・名前・提供する機能を示す。機能はモデル・MCP・カレンダー・ストレージ（Google ドライブ）に分け、単一選択のフィルターで絞り込み、「すべて」で解除する。サブスクリプションは行のクリックでそのまま認証を開始し、サインイン済みなら状態を表示して押せなくする。Databricks（workspace URL）と Google（権限とプライバシーポリシーの案内）は行をその場で展開し、展開内の「サインイン」で認証を開始する。展開中の行が絞り込みから外れたら閉じる。ChatGPT・Anthropic（Pi がサインインを持つ）、Databricks の接続、以前に追加した workspace、Google を並べ、追加・再サインイン・名前の変更・サインアウト・削除と、各アカウントが提供する capability を示す。「エージェント → モデル」はプロバイダーごとのモデルのオン・オフだけを持ち、アカウントの操作はこのページへ案内する。アプリのアカウントは 1 つで、今の Local Account を引き継ぐ（[単一アカウントへの移行](../../plans/2026-11-23-single-account-provider-accounts.md)）。Databricks の接続はアカウントではなく、そのアカウントが使うプロバイダーアカウントであり、モデル（Gateway）・MCP・カレンダー（Google Calendar の proxy）を提供する。設定の「Dahlia AI」はアカウントの provider と AI 設定を示す。Databricks の接続のサインアウトは設定の「プロバイダー」ページで行い、確認モーダルで対象を示す。確認後にだけ接続を切断し、キャンセル、閉じる、Escape、背景クリックでは切断しない。接続を削除しても、アカウントの履歴と設定は残り、その接続のモデル・MCP・カレンダーだけが使えなくなる。接続が 2 つ以上あるときは、当面最も古い 1 つだけを使う（Pi のプロバイダー ID が `databricks` で共通のため）。

Databricks の接続は複数持て、OAuth の token 処理は接続ごとに独立する。接続は `provider_accounts` テーブル（`kind = 'databricks'`、clientID は `databricks-cli`）に置き、利用者が付けた表示名（`name`、任意）を持てる。再サインインしても表示名は残す。表示名は設定の「プロバイダー」ページで変更し、空にすると workspace とメールアドレスを表示する。プロバイダー一覧、モデルの選択、カレンダーのプロバイダー、サインアウトの確認は表示名で示す。表示名はプロバイダー ID や認証の参照には使わない。0.29 までの UserDefaults の接続と Keychain の credential は起動時に削除して引き継がず、ユーザーには再サインインを案内する（Workspace とデータは Local Account に残る）。カレンダーソースと Google カレンダーの表示カレンダーは開いているアカウントごとに保存し（`enabledCalendarSources.<アカウント>`、`googleCalendarSelectedCalendarIDs.<アカウント>.<接続種別>.<接続 UUID>`。未設定のアカウントは従来のアプリ共通の値を引き継ぐ）、会議リンクを開くアプリも開いているアカウントごとにこの Mac へ保存する（未設定のアカウントは直前のアカウントの値を引き継ぐ）。Google カレンダーで前回取得した予定は、セッションの復元後に予定の再取得を待たず表示できるよう、アプリのアカウントと選択したプロバイダーごとの JSON ファイル（Application Support の `Caches/GoogleCalendar/<アカウント>-<プロバイダー>-<Google 利用者 ID のハッシュ>.json`）に丸ごと置き換えて保存し、切断で削除する。使い捨てのスナップショットなので SQLite には置かない。キャッシュはセッションを復元して Google 利用者 ID を確認した後、その利用者の予定だけを表示するために使う。proxy で主カレンダーが返らず利用者を特定できない場合はキャッシュを使わず、新規取得の結果を表示する。利用者を確認できなかった予定は、後で同じ ID が返っても確認済みの利用者の予定として流用しない。カレンダー一覧は全ページの取得完了後に表示カレンダーの選択と照合する。取得に失敗した更新は失敗とし、次の更新で一覧から再試行する。予定を選択していない一覧だけの更新にも通常の更新間隔を適用し、選択変更時はすぐに更新する。会議に保存した予定情報は新規取得の完了後に更新する。メニューバー表示と予定の絞り込みはアプリ共通とする。参加表明していない予定（仮承諾を含み、辞退済みを除く）と辞退済み予定は独立して表示を選べる。両方とも既定で非表示とし、表示する場合は未参加表明の予定を薄く、辞退済みの予定を薄く取り消し線付きでサイドバー・予定一覧・メニューバーに表示する。設定画面では、カレンダーのプロバイダーと予定の絞り込みを「機能 → カレンダー」の「カレンダーソース」「予定の表示」タブにまとめる。macOS カレンダーと、登録済みの Google・Databricks プロバイダーアカウントだけをモデルや MCP と同じく 1 つずつ折り畳んで並べ、行のスイッチでオンにし、中に接続状態と表示するカレンダーを置く。メニューバー表示は「この Mac → 外観」、会議リンクを開くアプリは「機能 → ミーティング」の「会議リンク」タブに置く。セットアップツアーのカレンダー手順は、ツアーで選んだアカウントに保存する。Google カレンダーと Drive のバックアップ読み取りは、利用者が選んだプロバイダーから読む。Google なら直接の Google OAuth、Databricks の接続ならその Unity Catalog connection proxy を使う。Google は「プロバイダーを追加」から複数登録できる。各登録は `provider_accounts` の `kind = 'google'` の行と UUID を持ち、表示名・Google 利用者 ID・メールアドレスをこの Mac に保存する。認証は登録 UUID ごとの Keychain に保存し、名前の変更・同じ Google 利用者での再サインイン・個別のサインアウトができる。追加時は名前・メールアドレスとカレンダー・Drive 内のすべてのファイルの読み取り権限をまとめて求める。Drive ではフォルダ・ファイル情報で `Dahlia/Backup` を探し、選択したバックアップだけをダウンロードする。権限の範囲と実際の用途を登録画面で示し、同じ登録の中でサインインを共有する。利用先を選ぶと許可済みの認証を再利用し、必要な権限が不足する場合や保存した認証を更新できなくなった場合だけ、明示的な接続操作で認証を求める。一時的な通信障害やキャンセルでは認証画面を開かない。Google と Databricks の表示カレンダー選択と予定キャッシュは登録ごとに分離し、未登録の Google をカレンダー設定やセットアップに表示しない。プロバイダーの追加では既存の有効な接続を変更せず、サインアウトでは対象の接続だけを停止する。別の接続の認証とカレンダー選択は残す。認証の削除に失敗した場合は、初回登録を保存できなかったときも、利用を無効にしたまま設定に削除の再試行を残す。未完了の登録はカレンダーの候補には含めない。直接の Google のサインアウトは、選択中のプロバイダーにかかわらず、その登録の表示カレンダー選択と予定キャッシュを削除する。他の Google 登録や Databricks の認証・選択・予定キャッシュは残す。Google が実際に許可した scope だけを保持する。許可しなかった用途は未接続のままとする。用途の切断はその用途の利用だけを止め、プロバイダーのサインアウトはその登録のカレンダーと Drive の両方を停止する。接続処理中に Drive の選択先が変わった場合、その処理から認証を開始したり接続状態を更新したりしない。共有サインインや選択したプロバイダーが変わると Drive の一覧を破棄し、取得時と同じアカウント・接続先の一覧からだけバックアップを取り込む。Databricks の proxy も取り込み前に現在の Google 利用者 ID を取得し、接続 ID が同じという理由で以前の利用者 ID を流用しない。用途ごとに分けていた以前のサインインは起動時に削除し、再サインインを求める。Google Calendar は登録済みの Google アカウントと Databricks 接続を複数同時に利用できる。設定とセットアップの各行で独立して有効・無効にし、認証、表示カレンダーの選択、取得状態とエラー、予定キャッシュを接続ごとに分離する。1 つの接続の失敗や削除は、他の接続の選択と予定取得を止めない。有効な接続の予定はサイドバー・予定一覧・メニューバー・会議検出で集約し、接続をまたいで同じ iCalendar UID と RECURRENCE-ID を持つ予定は重複表示しない。同じ接続内の複数カレンダーにある予定は保持する。複数アカウントに同じ予定がある場合、別アカウントでの辞退だけを理由に参加済みの予定を隠さない。削除した接続から他のプロバイダーへ自動で切り替えない。Drive の利用先はバックアップ設定で別に選択し、カレンダーの有効・無効では変更しない。Databricks の proxy は各用途で明示的に選んだ接続だけを使う。カレンダーの接続はプロバイダーアカウントとカレンダーサービスの組で識別し、将来の Microsoft 365 用 Databricks アダプターも Google と別の認証・選択・取得状態で集約できる境界とする。Microsoft 365 の取得と設定の候補は未実装。macOS カレンダーは OS の権限で読み、`provider_accounts` には置かない。proxy の認証には Databricks の Bearer token を使い、Google の credential は接続側が管理する。proxy 経由の JSON 読み取りで Google が 401 を返した場合は一度だけ再試行する。なお失敗する場合は接続ページで既存 credential を取り消して再認証するよう案内し、Databricks 自体の 401/403 や Google の 403 とは区別する。

Workspace はアカウントに属さない。起動時に、すべての Workspace の `workspaces.databricksConnectionId` を空にする。最後に開いていた Workspace が Databricks アカウントのものだった Mac では、その 1 回だけ、そのアカウントの履歴（`accountID` を持つ行）・アカウント別の設定・Pi のファイルを Local へ写す。元のディレクトリと設定のキーは残す。

Workspace を Databricks の接続へ移す操作と、接続ごとの `Default` は無い。アカウントの Workspace が無いときは `Default` を 1 つ作る。Workspace 選択画面の背景クリックでは離脱せず、キャンセル／閉じるボタンか Escape で明示的に取り消す。

Databricks の接続は設定の「プロバイダー」ページか、セットアップツアーのモデルの手順で追加する。ツアーにアカウントの手順は無い。モデルの手順は「プロバイダーを追加」の一覧を「モデル」で絞って埋め込み、サインインの後も閉じずに追加済みを示す。Databricks の保存済み接続は認証の有効性を表さない「登録済み」とし、再認証は初期設定の完了後に設定の「プロバイダー」で行う。カレンダーの手順は設定を開けないので、「プロバイダーを追加」のモーダルを「カレンダー」で絞って開く。追加の後に Workspace の移動や作成は尋ねず、開いている Workspace は変わらない。メイン画面のサイドバー下部のフッターはアカウントを示さず、設定のメニュー、未処理の録音（1 件以上のときだけ件数付きで出す）、アップデート（あるときだけ）、ヘルプを並べる。設定のメニューは言語と外観をその場で切り替える項目と、設定を開く項目を持つ。設定画面のサイドバーにはフッターを出さない。表示言語と外観は設定の「外観」で変更でき、外観はシステム・ライト・ダークのプレビューから選ぶ。Server Account（Dahlia account）のサインインは表示しない（未確定事項を参照）。

サインインした Dahlia account の Server の Gateway は、アプリのアカウントのプロバイダーアカウント（capability は model、Pi のプロバイダー ID は `dahlia`）とする（[内蔵 Pi runtime](pi-runtime.md) の provider 表）。`models.json` に `dahlia` provider を書き、モデル一覧の取得時に Gateway の catalog を更新する。サインインが 2 つ以上あるときは当面最も古い 1 つだけを使う（Pi のプロバイダー ID が `dahlia` で共通のため）。サインアウトすると provider を外す。

## 実行アカウントの context

実行アカウントは常にアプリのアカウントで、OpenAI / Anthropic の subscription と、プロバイダーアカウント（Databricks の接続の Gateway、Dahlia account の Gateway）を使う。`workspaces.accountConnectionId`・`organizationId`・`personalUserId` と同期の列は DB に残し、起動時にすべての Workspace で空にする。Server Workspace だった Workspace は、会議・文字起こし・ファイルを残したままアカウントの Workspace になる。Server にだけあった本文・画像・録音アーカイブは読めなくなる。処理場所が `remote` の Workspace の設定は `local` に戻す。

モデルは開いているアカウントのものだけを使う。設定には、そのアカウントの provider だけを表示する。AI 設定のスコープ、アカウント切替の処理、モデル設定の保存先は [アカウント別の Desktop 推論](../shared/account-scoped-desktop-inference.md) に従う。旧 Vault の summary 列は互換性のため保持するが、新規 summary の設定や実行先判定には使わない。

Pi の agent directory は `Application Support/Dahlia/agent` の 1 つにする。設定と行のアカウントのキー（`accountKey`）は常に `local`。以前に Server Account が使った `Application Support/Dahlia/accounts/<provider_accounts.id>/pi` は、その Dahlia account を削除すると消す。Server Account で走ったチャットとエージェントの行（`accountID` が接続の ID）は移さずに残し、画面には出さない。録音後の処理に保存した実行先は、`dahlia`・`databricksWorkspace`・`databricks` のキーも含めて `local` として読む。

## ChatGPT と Databricks Workspace OAuth

2026-09-10 に採択。Databricks provider は CLI に依存せず、Desktop が U2M OAuth を実行する。既存 CLI 設定・token cache は参照しない。利用者は Workspace URL を入力し、ブラウザで再サインインする。

public client は `databricks-cli`、scope は `offline_access all-apis` に固定する。redirect URI は `http://localhost:8020` から `8040` のうち待受できた最初のポートを使い、すべて使用中なら失敗を表示する。64 バイトの PKCE verifier と S256、state を使う。Workspace discovery の authorization / token endpoint を検証し、取得不能・不正なら同一 Workspace の `/oidc/v1/authorize` と `/oidc/v1/token` を使う。Server Account の resource / userinfo フローとは分離する。

Databricks 接続は HTTPS Workspace origin と認証境界用 UUID をこの Mac に保存する。同じ Workspace は再認証し、別 Workspace への変更はサインアウト後に行う。従来の `databricksProfile` 設定値は新しい接続の UUID を保持する互換フィールドとして使い、CLI profile 名には解決しない。旧 Vault 列と登録済み migration は保持する。credential は実行環境と接続 ID ごとの Keychain に保存し、refresh rotation の保存失敗では新 token を公開しない。サインアウトは選択接続と local credential を削除し、進行中更新の結果を拒否する。

token は要求ごとに標準入力で渡し、config・環境変数・log には残さない（[内蔵 Pi runtime](pi-runtime.md)）。Databricks の会話 turn 全体を再実行する回復経路は追加しない。

## 制約

設定画面を開いても、実行アカウントの context・設定ファイル・Server の token 認可は変更しない。

実ユーザーの HOME 継承により `$HOME/.agents/skills` が探索され得る。これは未監査の user skill であり、分離は未検証のまま残す。当面の最終境界は、要約での skill 無効化、MCP の Workspace 検証、[承認方針](chat-approval.md) とする。

## 未適合・未検証

- 未確定: Server Account のサインインの表示。記録では「当面表示しない」とし、接続の削除の導線がないため、サインインを戻すときに足すとする。Databricks をデータの正本にする場合の同期設計は別途行うとする。
- 未確定: Gateway の 401 時の強制 refresh と1回の再試行、ブラウザ認証の待受 300 秒、認証コマンドと broker の timeout（360 秒、365 秒、20 秒）、token 更新間隔 25 分、直接 Databricks provider の stream retry を 0 にすること、ChatGPT ログインの request shape は、Codex・auth-helper・token broker の経路の値である。Pi への置換（2026-11-06）後に同じ規則が有効かは [内蔵 Pi runtime](pi-runtime.md) に記載がなく未確定。Pi の bridge が要求元との対応を検証し、認証完了後に認可を再検証するかも未確定。
- 未検証: 実ユーザーの HOME 継承による `$HOME/.agents/skills` の分離。追跡 issue は [dahlia-org/dahlia#234](https://github.com/dahlia-org/dahlia/issues/234)。
