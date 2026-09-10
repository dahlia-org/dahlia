# Desktop の認証と account 分離

対象: Desktop。採択: 2026-08-04〜09-01。Server account の移行・サインアウト時のデータ扱いは、後続の [同期契約](../shared/sync.md#正本とアカウント境界) を優先する。

## 接続と Vault

Dahlia account はアプリ共有の接続として SQLite に UUID、正規化 origin、client ID、作成日時を保存する。Cloud は最大1件、Server は複数登録できるが同一 origin は一意。Cloud / Server 種別は現在の Cloud origin との一致から導出し、保存しない。

credential と remote identity / 表示情報は接続 UUID ごとの Keychain が所有する。token API は connection ID を必須にし、接続ごとの actor が refresh の集約と rotation の永続化を行う。credential がなければ再サインインを案内し、ローカル機能を妨げない。

sign-out は remote revocation を試みた後、結果にかかわらず local credential を削除し、失効失敗は通知する。これは当初の「失効成功まで local credential を残す」順序を変更したもの。Server canonical data は削除せず、local working copy の選択は同期契約に従う。未リリースの固定 Keychain key は移行しなかった。

## Codex account context

Vault の nullable connection ID は nil を Local Account とし、削除時は SET NULL。Local Account だけが ChatGPT Subscription / 直接 Databricks provider を選べ、Dahlia account はその Server の Gateway を使う。

Local Account は既存の `Application Support/Dahlia/Codex`、Dahlia account は接続 UUID ごとの private CODEX_HOME を使う。生成用の単一 app-server は context 切替時に新規操作を待たせ、進行中操作を drain して対象 home で再起動する。ローカルの認証管理だけは既存サービスの別インスタンスを使い、Local Account の home と OpenAI provider に固定する。設定画面を開いても生成用の context・設定ファイル・Server の token broker 認可を変更しない。認証変更後は ChatGPT を実行中の場合だけ生成用サービスを再読込する。

model discovery と生成は同じ root provider を使い、別の provider 専用 model cache を持たない。Dahlia token は既存 service actor から private local broker / Codex auth command へ動的に渡し、config・環境変数・log に保存しない。provider と Databricks 接続 ID はアプリ設定に保存する Local Account 共通設定とし、設定画面・セットアップ・生成・画像解析が同じ値を使う。Local処理のsummary model / effortもLocal Account共通設定とし、初回のみ最後に開いた Local Account の Vault から引き継ぐ。該当 Vault がなければ従来のアプリ設定を使う。旧 Vault のsummary列は互換性のため保持するが、新規summaryの設定や実行先判定には使わない。chat model / effort は引き続き Vault に保存する。同一 origin の複数 remote account 切替は対象外。

アカウント一覧は Local Account を常時含め、現在の Vault の所属アカウントにチェックを表示する。モデルプロバイダー設定は常に Local Account を対象とし、Dahlia Server / Cloud の hosted provider は設定項目として表示しない。

## ChatGPT と Databricks Workspace OAuth

2026-09-10: 直接 Databricks provider は CLI への依存を廃止し、Desktop が U2M OAuth を実行する。既存 CLI 設定・token cache は参照しない。利用者は Workspace URL を入力し、ブラウザで再サインインする。

public client は `databricks-cli`、redirect URI は `http://localhost:8020`、scope は `offline_access all-apis` に固定する。64 バイトの PKCE verifier と S256、state を使い、8020 が使用中なら別ポートへ変更せず失敗を表示する。Workspace discovery の authorization / token endpoint を検証し、取得不能・不正なら同一 Workspace の `/oidc/v1/authorize` と `/oidc/v1/token` を使う。Dahlia Server の resource / userinfo フローとは分離する。

Databricks 接続は HTTPS Workspace origin と認証境界用 UUID をこの Mac に1件だけ保存する。表示名・接続一覧・選択は持たず、Codex 設定は常に `model_providers.databricks` を使う。同じ Workspace は再認証し、別 Workspace への変更はサインアウト後に行う。従来の `databricksProfile` 設定値は新しい接続の UUID を保持する互換フィールドとして使い、CLI profile 名には解決しない。旧 Vault 列と登録済み migration は保持する。credential は実行環境と接続 ID ごとの Keychain に保存し、refresh rotation の保存失敗では新 token を公開しない。サインアウトは選択接続と local credential を削除し、進行中更新の結果を拒否する。

Databricks / Dahlia Server の認証コマンドは共通の `auth-helper token --provider <databricks|dahlia> --connection-id <UUID> --profile <production|development>` に移す。MCP executable は認証コマンドを持たない。helper は token broker のクライアントだけを担い、接続 URL・OAuth・Keychain は Desktop が所有する。broker は接続種別・ID、実行環境、helper 実行ファイル、親 Codex PID を検証し、認証完了後も認可を再検証する。token は認証コマンドの標準出力から Codex に渡し、config・環境変数・log には残さない。

チャットとこの Mac の推論は独立した認可を broker に登録する。一方の再起動で他方の認可を消さず、接続の検証には要求元の親 PID に対応する認可だけを使う。broker は最大8接続を並行処理し、ブラウザ認証待ちで他の runtime を塞がない。認証保存直後に設定画面を閉じた場合も、再表示時に保存済み接続の UUID を設定へ復元する。

Codex は Gateway に Bearer token を送る。401 による認証コマンド再実行では Databricks token を強制 refresh し、同一 HTTP request を1回だけ再試行する。固定版 Codex は stream retry ごとに認証回復を繰り返すため、直接 Databricks provider は `stream_max_retries = 0` とする。これによりストリーム切断時も自動再実行せずエラーを返す。refresh 失敗ではブラウザ認証へ進み、待受は300秒で終了する。ネットワーク時間を含め broker は360秒、helper クライアントは365秒、Codex auth command は20秒を上限にし、token の定期更新間隔は25分とする。ブラウザ認証が20秒以内に完了しなければ、その認証コマンドはタイムアウトする。Databricks を対象に会話 turn 全体を再実行する回復経路は追加しない。

ChatGPT の `account/login/start` は `type: chatgpt` だけを指定し、hosted success page / appBrand を省略する。HTTPS auth URL を開き、login ID に対応する completed notification を待つ。固定 Codex 更新時は既定のローカル成功ページと request shape を認証回帰で確認する。

## 経緯と制約

接続だけを先行追加した時点の「Vault 関連は sync と同時に追加」という保留は、AI provider consumer の導入で解除した。後続の canonical sync は sign-in による暗黙移行と独立した sync toggle を廃止した。接続関連だけの初期 AI contract を、現在の Server account のデータ lifecycle に一般化しない。

実ユーザー HOME の継承により `$HOME/.agents/skills` が discovery され得る。これは未監査の user skill であり、分離は [追跡 issue](https://github.com/dahlia-org/dahlia/issues/234) の未検証事項として残す。summary の skills 無効化、Vault MCP validation、[承認方針](chat-approval.md) を最終境界とする。
