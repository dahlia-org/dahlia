# 内蔵 Pi runtime

対象: Desktop の要約・画像解析・画像選別・チャット。採択: 2026-11-06。ユーザー承認済み。
[Codex runtime と stdio](codex-runtime.md)、[チャットの承認](chat-approval.md)の実行方式、
[アカウント](accounts.md#codex-account-context)の CODEX_HOME・auth-helper・token broker を置き換える。

## Pi の実行ファイル

Dahlia は Pi を同梱せず、利用者がインストールした `pi` を使う（2026-11-07 にユーザー承認、同梱を廃止）。
実行する `pi` は、エージェント設定の絶対パス、PATH 上の `pi` の順に選ぶ。Finder から開いたアプリは launchd の
最小 PATH しか受け取らないため、PATH に `/opt/homebrew/bin`・`/usr/local/bin`・`~/.local/bin`・`~/bin` を加えて探す。
指定したパスに実行ファイルがない、または見つからないときは `piCommandNotFound` で失敗し、要約・画像解析は
未サインインと同じく保留にする。版は固定しないため、`dahlia.ts` が使う RPC と extension API の互換は
Pi の更新時に `test-pi-extension.py` で確かめる。ユーザーの `~/.pi` は使わない。

## Process と境界

Pi の agent directory はアカウントごとに `Application Support/Dahlia/accounts/<local または accounts.id>/pi`（0700）。
Local Account は `local`、Databricks アカウントと Dahlia account は `accounts` テーブルの ID を使う。`PI_OFFLINE`・`PI_SKIP_VERSION_CHECK`・`PI_TELEMETRY=0` と、
extension・skill・context file・prompt template・theme・project trust の自動読込の無効化で起動し、
Dahlia の extension（`PiExtension/dahlia.ts`）だけを `-e` で読み込む。チャットは Dahlia MCP と Unity AI Gateway の MCP のために Pi の `builtin:mcp` も読み込み、`--tools` に `mcp__dahlia__*` と有効にした gateway MCP の `mcp__<name>__*` を含める。

- 要約・画像解析・画像選別・モデル一覧・サインインは操作ごとに `pi --mode rpc --no-session --no-tools` を起動し、終了・取消・610秒期限で閉じる。自動再送はしない。
- チャットは turn の開始時に thread ごとに1 process を起動し、turn 後はチャット画面が thread を開いている間だけ残す。履歴の表示や新規 thread の作成では起動しない。process が終了していれば次の turn で session file から開き直す。
- アカウント切替は全 process を閉じ、切替先の agent directory の `models.json` を書き換える。実行中の要約は取消になり、次の操作で新しいアカウントの process を起動する。
- OpenAI / Anthropic のサインイン・サインアウトは Local Account の process だけを閉じる。Databricks アカウントのサインアウトでは、そのワークスペースが Local Account に戻り、agent directory（チャット履歴を含む）は残す。
- stdout の1行は 4 MiB（送った最大行の分を加える）までとし、超えた行は改行まで捨てて読み続ける。Pi の `turn_end`・`agent_end` は run のメッセージを画像ごと繰り返すが、Dahlia は読まない。
- Dahlia は RPC の extension UI（`ctx.ui.input("dahlia:<method>")`）でだけ extension と通信する。token は要求ごとに stdin で渡し、config・環境変数・log に残さない。
- Databricks アカウントと Dahlia account の provider（`DAHLIA_PI_BRIDGED_PROVIDERS`）は、extension が pi-ai の `createProvider` で認証だけを持つ provider として登録し、使うたびに bridge の `token` で credential を解決する（モデルは `models.json` を重ねる。session 開始前の利用可否の確認には要求に使わない仮の値を返す）。`models.json` に key は書かない。MCP は `mcp.json` の項目の `auth.provider` でこの provider の credential を要求ごとに使う（Pi の文書にない項目で、Pi 更新時に回帰確認する）。

## Provider

Local Account は OpenAI と Anthropic に別々にサインインでき、サインイン済みの両方のモデルをまとめて一覧に出す。Databricks アカウント（接続した workspace ごとに1つ）は
自分の agent directory を持ち、実行アカウント `databricks(connectionID:)` として、その workspace の Gateway のモデルだけを一覧に出す。どのモデルを出すかは実行アカウントの provider ID で決まる（[アカウント](accounts.md#codex-account-context)）。
表示名は Pi の名前に合わせる（`openai` は「OpenAI (ChatGPT subscription)」。「ChatGPT Plus/Pro」は Pi の旧 `openai-codex` の名前）。Dahlia account は自分の Server の provider だけを使う。

| 表示名 | Pi provider | 認証 |
| --- | --- | --- |
| OpenAI (ChatGPT subscription) | `openai`（Sign in with ChatGPT、agent 名 `Dahlia`） | Pi の OAuth。端末 ID は Local agent directory |
| Anthropic (Claude Pro/Max) | `anthropic` | Pi の OAuth |
| Databricks | `databricks`（各モデルが Unity AI Gateway の経路を持つ: Claude は anthropic、GPT は codex、GLM・Kimi は mlflow、Gemini は gemini） | その Databricks アカウントの Desktop OAuth を bridge |
| Dahlia account | `dahlia`（Server の `/api/v1/responses`） | Dahlia token を bridge |

Databricks のモデル一覧は `PiExtension/databricks-models.json` に同梱する。Dahlia account は切替時に Server の URL だけを記録し（network 不要）、
モデル一覧の取得時に `/api/v1/models` を `models.json` に変換する。取得に失敗したら直前の一覧を保ち、空の一覧はキャッシュしない。
一覧は account ごとに1つの Pi 起動を同時の呼び出し元すべてで共有し、全員が取り消したときだけ止める。サインイン・サインアウト・
アカウント切替はキャッシュを捨て（それ以前に始まった取得の結果も保存しない）、`DahliaPiModelsDidChange` を通知する。
設定・要約の確認・チャットのモデル選択はその通知で読み直す。画面を開くだけではキャッシュを使い、再試行だけが取得し直す。モデルは `provider/id` で保存し、Codex 時代の
裸のモデル名は ID の末尾一致で移行する。見つからなければ保存値を変えず、その要求だけ先頭の利用可能モデルを使う。

サインインは extension の `/dahlia-login` が Pi の login を呼ぶ。Pi の extension API に login がないため
非公開の `modelRegistry.runtime` を使い、Pi 更新時に回帰確認する。subscription の利用条件（OpenAI の
Sign in with ChatGPT 登録区分、Anthropic の第三者利用）はライセンスとは別に確認が残る。

## 構造化出力

Pi は最終応答の JSON Schema を持たない。system prompt に schema を含め、OpenAI Responses の経路
（ChatGPT・Dahlia・Databricks codex）だけ extension が `text.format`（strict）を付ける。Dahlia は返答を
JSON object として検証し、型で decode できない返答・拒否・空・`stopReason` が `stop` 以外は生成失敗にする。
要約の Markdown fallback には流さない。

## チャットの実行と承認

チャットはこの Mac では読み取り専用とする。Pi に渡す tool は `read`・`ls`・`mcp__dahlia__*` と、Databricks アカウントで有効にした Unity AI Gateway の MCP だけで、bash・write・edit・grep・find はない。
`read` と `ls` は workspace と Dahlia の preset skill の folder（`DAHLIA_PI_READABLE_ROOTS`）の中だけを読める。extension は
`@`・`~`・`file://`・相対 path を解決し、symlink と大文字小文字を実体の path に揃えてから範囲を確かめ、確かめた path を Pi に渡す。

| 選択 | read / ls | Dahlia MCP | Unity AI Gateway の MCP |
| --- | --- | --- | --- |
| 承認を求める | 範囲内は確認なし | 読み取り（`get`・`query`・`list`・`search`）以外は承認 | server が `readOnlyHint` を付けた tool 以外は承認 |
| 代わりに承認 | 範囲内は確認なし | 確認なし | 確認なし |

MCP の tool は、Dahlia がその chat に登録した server（Dahlia MCP と有効な gateway MCP。`DAHLIA_PI_MCP_SERVERS`）のものだけを通し、それ以外の server の tool は承認方式にかかわらず拒否する。承認の表示で承認できるのもこれらの server だけとする。
gateway MCP の tool が読み取りかどうかは、server が付けた `readOnlyHint` をそのまま使う（2026-11-07 ユーザー承認）。

承認方式は Dahlia が保持する。extension は、表で承認が要る MCP tool（Dahlia MCP・gateway MCP とも）を呼ぶたびに bridge で承認方式を問い合わせる（turn 中の変更も次の呼び出しから効く。不明なら「承認を求める」）。
Codex 時代のフルアクセスは提供しない。承認方式は Pi の session file に残さず、新しい thread も開き直した thread も「承認を求める」で始まる。
承認の表示は既存の上限（20 KB など）で切り詰め、取消・停止は未応答の承認を cancel してから abort する。
Codex の auto_review と web search、`request_user_input` は Pi にないため提供しない。

### Unity AI Gateway の MCP

採否は[エージェントによる MCP 経由の外部サービス操作](agent-mcp-operations.md)に従う。
Databricks アカウントは、設定の「エージェント」で workspace の Unity AI Gateway の外部サービス MCP
（`system.ai.gmail`・`google_calendar`・`google_drive`・`slack`・`github`・`atlassian`・`microsoft_365`）を
アカウントごとに有効にできる（既定はすべて無効）。チャットの process を起動するたびに、Dahlia は有効な MCP を
アカウントの agent directory の `mcp.json`（0600）に `<workspace>/ai-gateway/mcp-services/system.ai.<name>` の
`url`・`exposure: "direct"`・`auth: { provider: "databricks" }` だけで書く（有効なものがなければ空）。credential は書かず、
モデルと同じ Databricks OAuth token が要求ごとに付く。Pi の MCP OAuth（`mcp-auth.json`）は使わない。
サービスへのサインインは MCP が返すリンクで行い、Dahlia は扱わない。Pi は `mcp.json` を起動時にだけ読むので、設定の変更は
その後に起動する chat process から効く。開いている thread の process は、閉じるまで前の設定のまま動く（遅れはユーザーが許容。2026-11-07）。
`--tools` と `DAHLIA_PI_MCP_SERVERS` は process ごとに同じ時点の設定から作るので、別の thread が先に書いた新しい `mcp.json` を読んでも、
その process で使える MCP は起動時の設定の範囲に留まる。Local Account と Dahlia account では使えない。

履歴の正本は Pi の session file（実行アカウントの agent directory の `sessions/<Workspace ID>`）。モデルと同じくアカウントに属し、Workspace を別のアカウントへ移しても移さない。移動先では、そのアカウントでの履歴だけを表示する。Codex の rollout は表示せず、
ファイルは削除しない。

## 検証

fake transport で RPC の順序・失敗・取消を、`test-pi-extension.py` で実 Pi とローカル gateway の
token bridge（Anthropic・Gemini・OpenAI の各 API、`auth.provider` のない MCP と redirect 先に付かないこと）・strict schema・読み取り範囲・MCP の承認を確認する。Pi 更新時は RPC event、extension API、
login の非公開 API、`text.format` の payload 形を回帰確認する。
