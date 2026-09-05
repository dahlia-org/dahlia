# Desktop の認証と account 分離

対象: Desktop。採択: 2026-08-04〜09-01。Server account の移行・サインアウト時のデータ扱いは、後続の [同期契約](../shared/sync.md#正本とアカウント境界) を優先する。

## 接続と Vault

Dahlia account はアプリ共有の接続として SQLite に UUID、正規化 origin、client ID、作成日時を保存する。Cloud は最大1件、Server は複数登録できるが同一 origin は一意。Cloud / Server 種別は現在の Cloud origin との一致から導出し、保存しない。

credential と remote identity / 表示情報は接続 UUID ごとの Keychain が所有する。token API は connection ID を必須にし、接続ごとの actor が refresh の集約と rotation の永続化を行う。credential がなければ再サインインを案内し、ローカル機能を妨げない。

sign-out は remote revocation を試みた後、結果にかかわらず local credential を削除し、失効失敗は通知する。これは当初の「失効成功まで local credential を残す」順序を変更したもの。Server canonical data は削除せず、local working copy の選択は同期契約に従う。未リリースの固定 Keychain key は移行しなかった。

## Codex account context

Vault の nullable connection ID は nil を Local Account とし、削除時は SET NULL。Local Account だけが ChatGPT Subscription / 直接 Databricks provider を選べ、Dahlia account はその Server の Gateway を使う。

Local Account は既存の `Application Support/Dahlia/Codex`、Dahlia account は接続 UUID ごとの private CODEX_HOME を使う。生成用の単一 app-server は context 切替時に新規操作を待たせ、進行中操作を drain して対象 home で再起動する。ローカルの認証管理だけは既存サービスの別インスタンスを使い、Local Account の home と OpenAI provider に固定する。設定画面を開いても生成用の context・設定ファイル・Server の token broker 認可を変更しない。認証変更後は ChatGPT を実行中の場合だけ生成用サービスを再読込する。

model discovery と生成は同じ root provider を使い、別の provider 専用 model cache を持たない。Dahlia token は既存 service actor から private local broker / Codex auth command へ動的に渡し、config・環境変数・log に保存しない。provider と CLI profile はアプリ設定に保存する Local Account 共通設定とし、設定画面・セットアップ・生成・画像解析が同じ値を使う。初回のみ最後に開いた Local Account の Vault から引き継ぎ、該当 Vault がなければ従来のアプリ設定を使う。旧 Vault 列は互換性のため保持するが、実行先の判定には使わない。summary / chat model と effort は引き続き Vault に保存し、新規は作成時の active Vault から継承する。同一 origin の複数 remote account 切替は対象外。

アカウント一覧は Local Account を常時含め、現在の Vault の所属アカウントにチェックを表示する。モデルプロバイダー設定は常に Local Account を対象とし、Dahlia Server / Cloud の hosted provider は設定項目として表示しない。

## ChatGPT と Databricks CLI

ChatGPT の `account/login/start` は `type: chatgpt` だけを指定し、hosted success page / appBrand を省略する。HTTPS auth URL を開き、login ID に対応する completed notification を待つ。固定 Codex 更新時は既定のローカル成功ページと request shape を認証回帰で確認する。

直接 Databricks provider は外部 CLI の OAuth profile を使う。専用 CODEX_HOME と実ユーザー HOME の継承を両立し、`~/.codex` の状態は参照しない。HOME を専用領域へ差し替える方式は、設定画面で検証済みの CLI credential を子 process から使えなくしたため廃止した。

CLI は同梱・自動取得せず、公式導入・license・privacy を案内する。利用者の導入操作で固定 Homebrew command を新しい Terminal session に渡し、Apple Events 拒否時は copy / open へ縮退する。Homebrew 自体は導入しない。

profile 名と HTTPS workspace root を受け、引数配列で CLI login を実行する。同名・同 host の OAuth profile だけを再利用し、別 host / 認証方式を上書きしない。token、config、app-server reload、model 一覧まで成功して初めて設定を有効化し、失敗・dialog cancel では従来の有効設定を戻す。既存 profile 選択と導入後の再検出を維持する。

## 経緯と制約

接続だけを先行追加した時点の「Vault 関連は sync と同時に追加」という保留は、AI provider consumer の導入で解除した。後続の canonical sync は sign-in による暗黙移行と独立した sync toggle を廃止した。接続関連だけの初期 AI contract を、現在の Server account のデータ lifecycle に一般化しない。

実ユーザー HOME の継承により `$HOME/.agents/skills` が discovery され得る。これは未監査の user skill であり、分離は [追跡 issue](https://github.com/dahlia-org/dahlia/issues/234) の未検証事項として残す。summary の skills 無効化、Vault MCP validation、[承認方針](chat-approval.md) を最終境界とする。
