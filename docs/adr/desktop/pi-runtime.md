# 内蔵 Pi runtime

対象: Desktop の要約・画像解析・画像選別・チャット。採択: 2026-11-06。ユーザー承認済み。
[Codex runtime と stdio](codex-runtime.md)、[チャットの承認](chat-approval.md)の実行方式、
[アカウント](accounts.md#codex-account-context)の CODEX_HOME・auth-helper・token broker を置き換える。

## Pi の実行ファイル

Dahlia は Pi を同梱せず、利用者がインストールした `pi` を使う（2026-11-07 にユーザー承認、同梱を廃止）。
実行する `pi` は、Dahlia AI 設定の「アプリ管理下の Pi を使う」で切り替える（2026-11-12 ユーザー承認）。
オフが既定で、PATH 上の `pi` を探索して表示・利用する。オンでは Dahlia がインストールした `bin/pi` のパスを表示・利用する。
実行ファイルのパスやコマンド名は手入力させない。選択は実行アカウントごとに保存し（agent directory と同じ `local` またはアカウント ID で区別）、
Dahlia がインストールする Pi はアプリプロファイルごとに全アカウントで共有する。以前のパス設定がその `bin/pi` を指していたアカウントはオンを引き継ぎ、
それ以外の旧設定は PATH 探索に切り替える。明示的に切り替えたトグルは旧設定より優先する。
Finder から開いたアプリは launchd の最小 PATH しか受け取らないため、PATH に `/opt/homebrew/bin`・`/usr/local/bin`・`~/.local/bin`・`~/bin` を加えて探す。
アカウントが「環境変数」で PATH を設定していれば、起動する Pi と同じく、その PATH で探す。
選択した Pi が見つからないときは `piCommandNotFound` で失敗し、別の Pi にはフォールバックせず、要約・画像解析は未サインインと同じく保留にする。
切り替えは以後起動する Pi process に適用する。

オンのとき、未インストールなら「Pi をインストール」、インストール済みなら「アップデートを確認」を出す。
インストール・更新中にオフへ切り替えても、その選択は保持する。インストールも更新もボタンを押したときだけ GitHub の
`earendil-works/pi` の latest release を取得し、`pi-darwin-arm64.tar.gz` を API の asset URL（`Accept: application/octet-stream`。github.com の `browser_download_url` は HTTP 504 を返したことがある）から取得し、GitHub が示す SHA-256 で確かめてから
`Application Support/<profile>/Pi/releases/<version>` に展開する。Dahlia が入れるコマンドは `Application Support/<profile>/bin`
に集め、入口の `bin/pi` は `../Pi/releases/<version>/pi` への symlink で、一時 link の rename で張り替える。Pi は symlink を解決した実体の位置から resource を実行中も読むため、
張り替えたあとは、新しい版、直前の版、process table（`proc_pidpath`）で動いている process の実行ファイルを含む版だけを残す。
直前の版は、古い link を解決して起動の途中にある process のため。Pi の入れ替えと掃除は `Pi/.lock` の flock で
process をまたいで1つずつ行う。展開済みの版はダウンロードしない。
失敗しても入口は前の版を指したまま。release の `pi` は ad-hoc 署名のまま実行でき、Dahlia は署名し直さない。
PATH 上の `pi`（npm・Homebrew など）は利用者のものとして更新しない。

`Dahlia --install-pi [version]` は app を開かずに同じ手順で版を入れる（版を省くと latest）。`bin/pi-update` は
これを呼ぶ shell script で、版を入れるたびに書き直すので app の場所に追従する。GitHub の release の `pi` は自分では
更新できないため、`bin` を PATH に入れてターミナルで使う人は、Pi 1.5.0 以降の `PI_SELF_UPDATE_COMMAND` に
`pi-update {version}` を設定する。Pi はこの変数を空白で区切るので、空白を含む `Application Support` の
フルパスは書けない。Pi はこの変数をどの入れ方の `pi` にも使うので、別の `pi` が PATH の先にあるときは設定しない。Dahlia は利用者の shell 設定や `~/.pi` には書かない。版は固定しないため、`dahlia.ts` が使う RPC と extension API の互換は
Pi の更新時に `test-pi-extension.py` で確かめる。ユーザーの `~/.pi` は使わない。

利用者は「エージェント」>「一般」の「環境変数」で、アカウントのすべての Pi process（要約・チャット・control）に環境変数を足せる
（2026-11-09 ユーザー承認。`piLaunch.<local またはアカウント ID>`）。Dahlia が設定する変数より先に入れるので、Dahlia の指定
（agent directory・`PI_OFFLINE` など）が勝つ。秘密にした値は Keychain（`piEnvironment.<profile>.<アカウント>.<変数 ID>`）に置き、
起動のたびに読む。設定画面には戻さない。変数名が環境変数として不正なもの、値のないものは渡さない。起動引数は足させない。

## Process と境界

Pi の agent directory はアカウントごとに `Application Support/Dahlia/accounts/<local または accounts.id>/pi`（0700）。
Local Account は `local`、Databricks アカウントと Dahlia account は `accounts` テーブルの ID を使う。`PI_OFFLINE`・`PI_SKIP_VERSION_CHECK`・`PI_TELEMETRY=0` と、
extension・context file・theme・project trust の自動読込を無効化して起動する。チャットではアカウントに追加したパッケージの skill・prompt template を読み込む（2026-11-12 ユーザー承認）。要約・画像解析・control は skill・prompt template も無効にする。
「Dahlia AI」>「パッケージ」から npm source または Git URL を Pi の `install`・`remove` で管理し、同じアカウントの `settings.json` を一覧の正本にする。変更は次に開始するチャット process から適用する。
パッケージ操作はアカウントの Pi 選択と環境変数を使い、`PI_CODING_AGENT_DIR` は Dahlia のアカウント directory に固定する。`~/.pi` や project の設定には追加しない。拡張コードは無効のままとし、インストール元は利用者が信頼できるものを指定する。

Dahlia の extension（`PiExtension/dahlia.ts`）を `-e` で読み込む。チャットは Dahlia MCP と登録した MCP server のために Pi の `builtin:mcp` も
読み込み、`--tools` に `mcp__dahlia__*` と登録した server の `mcp__<name>__*` を含める。

チャットがこの Mac の disk に対して行うことは、すべて Apple Seatbelt（`/usr/bin/sandbox-exec` と `PiExtension/pi.sb`）の中で動く（2026-11-11 ユーザー承認）。対象は `bash` のコマンドと、
`read`・`ls`・`write`・`edit` の file 操作で、起動される process も同じ制限を受け継ぐ。
Pi 本体は sandbox の外で動かす。Seatbelt は入れ子にできず、Pi を中に入れるとコマンドも Pi と同じ権限になり、agent directory の sign-in を読めて MCP server を承認なしで呼べるためである（Codex・Claude Code と同じ形）。

| 対象 | 許可 |
| --- | --- |
| 作業フォルダ、sandbox 用の一時フォルダ（`<一時フォルダ>/dahlia-chat`。sandbox の中の `TMPDIR` と `HOME`） | 読み書き |
| チャットの Pi の一時フォルダ（`<一時フォルダ>/dahlia-pi`。Pi の `TMPDIR`） | 読み取りだけ。Pi が長い出力の全文をここに保存する。Pi は変換した extension もここから読み込むので、書き込みは許さない |
| sandbox の外で実行されるもの: インストールされた Pi（実行ファイルの実体の folder。npm package なら `node` を含む prefix）、Dahlia の extension と skill、上の Pi の一時フォルダ | 書き込み不可（作業フォルダがこれを含んでいても） |
| Dahlia の preset skill、アカウントの Pi directory の `npm`・`git` 配下（インストール済みパッケージ）、画像の保存先（`FileStore`）、app の SQLite（`dahlia.sqlite` と `-wal`・`-shm`） | 読み取りだけ（画像と SQLite はデバッグ用） |
| Dahlia の Application Support のそれ以外（全アカウントの agent directory、録音、backup。development build からは production のものも） | 読み書き不可（作業フォルダがこれを含んでいても） |
| システムと全ユーザー向けの tool（`/System`・`/usr`・`/bin`・`/sbin`・`/Library/Developer`・`/Applications`・`/opt`・`/private/etc` など、`pi.sb` に名前で列挙） | 読み取りだけ。ただし local service の data と設定（`/opt/homebrew`・`/usr/local` の `var` と `etc`）は不可 |
| それ以外すべて（ホーム、`/Volumes`、利用者の一時フォルダと cache など） | 読み書き不可（metadata は読める） |
| IP の network | すべて許可（当面）。この Mac 自身の service（ブラウザの debug port、ローカルの DB）にも届く。Seatbelt の address の条件は IPv4-mapped IPv6（`::ffff:127.0.0.1`）を localhost として扱わないので、localhost だけを確実に閉じることはできない |
| Unix socket | DNS（mDNSResponder）だけ。ssh-agent、Docker、Dahlia の broker には届かない |

画像の保存先と SQLite は全 Workspace・全アカウントの内容を含む。Dahlia MCP の Workspace 境界（PRODUCT.md の T4）の外にある、デバッグ用の読み取りとしてユーザーが承認した例外である。
network は開いているので、読める内容は外部に送信できる。

extension は `read`・`ls`・`write`・`edit`・`bash` を Pi の `create*Tool` で登録し直す。file 操作（読み取り・一覧・書き込み・folder の作成・画像の判定）は `sandbox-exec` の中の `cat`・`ls`・`mkdir`・`head` で行い、
`bash` は `spawnHook` でコマンドを包む。path は開くときに kernel が判定するので、コマンドが作った symlink や検査後の差し替えで範囲の外に出ることはない。extension は path を検査しない。
sandbox の引数は Dahlia が `DAHLIA_PI_SANDBOX` で渡す。引数がないとき、または呼ばれる tool が Pi の built-in のまま（extension の登録が置き換えていない）のときは、5つの tool を拒否する。
本当のホームは読めないので、`git` などの設定は一時フォルダに置かれ、ホームの下に入れた tool（uv・nvm・pyenv など）は sandbox の中では動かない。sandbox の中の環境からは、利用者が「環境変数」で秘密にした変数（`DAHLIA_PI_SANDBOX_HIDDEN_ENV`）を除く。
作業フォルダはチャットが書けるので、Pi がそこから設定を読まないことが前提になる。Pi は `--no-approve` で project の設定（`.pi/mcp.json` など）を無視する。
Dahlia MCP は Pi の子のままで、コマンドは SQLite に書けず MCP にも届かないので、Dahlia のデータの変更は上記の承認方式に従う MCP の tool だけが行う。
Pi の codemode（未有効）の script は Pi の process 内の QuickJS で動き、file system も network も持たない。script が呼ぶ tool には同じ制限（Seatbelt と MCP の承認）が掛かる。

- 要約・画像解析・画像選別・モデル一覧・サインインは操作ごとに `pi --mode rpc --no-session --no-tools` を起動し、終了・取消・610秒期限で閉じる。自動再送はしない。
- チャットは turn の開始時に thread ごとに1 process を起動し、turn 後はチャット画面が thread を開いている間だけ残す。履歴の表示や新規 thread の作成では起動しない。process が終了していれば次の turn で session file から開き直す。スラッシュ候補の取得は既存 process を使い、なければ同じチャット用 resource を読む `--no-session` の一時 process を取得完了・失敗・取消で閉じる。
- アカウント切替は全 process を閉じ、切替先の agent directory の `models.json` を書き換える。実行中の要約は取消になり、次の操作で新しいアカウントの process を起動する。
- OpenAI / Anthropic のサインイン・サインアウトは Local Account の process だけを閉じる。Databricks アカウントのサインアウトでは、そのワークスペースが Local Account に戻り、agent directory（チャット履歴を含む）は残して、そのアカウントの `auth.json` と環境変数の秘密値は消す。Dahlia account を削除すると、agent directory ごと消し、環境変数の秘密値も消す。
- stdout の1行は 4 MiB（送った最大行の分を加える）までとし、超えた行は改行まで捨てて読み続ける。Pi の `turn_end`・`agent_end` は run のメッセージを画像ごと繰り返すが、Dahlia は読まない。
- Dahlia は RPC の extension UI（`ctx.ui.input("dahlia:<method>")`）でだけ extension と通信する。token は要求ごとに stdin で渡し、config・環境変数・log に残さない。
- Databricks アカウントと Dahlia account の provider（`DAHLIA_PI_BRIDGED_PROVIDERS`）は、extension が pi-ai の `createProvider` で認証だけを持つ provider として登録し、使うたびに bridge の `token` で credential を解決する（モデルは `models.json` を重ねる。session 開始前の利用可否の確認には要求に使わない仮の値を返す）。`models.json` に key は書かない。
- Unity AI Gateway の sign-in は、extension が OAuth の provider として登録する（[Unity AI Gateway の MCP](#unity-ai-gateway-の-mcp)）。モデルは Dahlia が `models.json` に書く。`mcp.json` の項目は `auth.provider` でその credential を要求ごとに使う（Pi の文書にない項目で、Pi 更新時に回帰確認する）。

## Provider

Local Account は OpenAI と Anthropic に別々にサインインでき、サインイン済みの両方のモデルをまとめて一覧に出す。サインインは
「Dahlia AI」>「モデル」の「プロバイダー」で行う（セットアップツアーにも残す）。「プロバイダー」には、アカウント自身のサインインと、
サインイン済みのサブスクリプション、追加した Databricks を並べ、それぞれに使い道（「モデル」「MCP」）のバッジを付ける（Databricks は両方）。サブスクリプションと
Databricks は「プロバイダーを追加」のモーダルで選んで追加する（サブスクリプションは Local Account だけ）。設定のモーダルは窓全体に重ねる。Databricks アカウント（接続した workspace ごとに1つ）は
自分の agent directory を持ち、実行アカウント `databricks(connectionID:)` として、その workspace の Gateway のモデルを一覧に出す。どのモデルを出すかは実行アカウントの provider ID で決まり（[アカウント](accounts.md#codex-account-context)）、
どのアカウントでも「プロバイダー」に追加した Databricks の workspace（ID がホスト名でドットを含む provider）のモデルも加わる。
表示名は Pi の名前に合わせる（`openai` は「OpenAI (ChatGPT subscription)」。「ChatGPT Plus/Pro」は Pi の旧 `openai-codex` の名前）。Dahlia account は自分の Server の provider だけを使う。

| 表示名 | Pi provider | 認証 |
| --- | --- | --- |
| OpenAI (ChatGPT subscription) | `openai`（Sign in with ChatGPT、agent 名 `Dahlia`） | Pi の OAuth。端末 ID は Local agent directory |
| Anthropic (Claude Pro/Max) | `anthropic` | Pi の OAuth |
| Databricks | `databricks`（各モデルが Unity AI Gateway の経路を持つ: Claude は anthropic、GPT は codex、GLM・Kimi は mlflow、Gemini は gemini） | その Databricks アカウントの Desktop OAuth を bridge |
| Unity Gateway (ホスト名) | 追加した workspace のホスト名（経路は `databricks` と同じ。モデル名にホスト名の先頭の部分を付ける） | Pi の OAuth（[Unity AI Gateway の MCP](#unity-ai-gateway-の-mcp) と同じ sign-in） |
| Dahlia account | `dahlia`（Server の `/api/v1/responses`） | Dahlia token を bridge |

Databricks のモデル一覧は Unity Catalog の `/api/2.1/unity-catalog/model-services?parent=schemas/system.ai` から作るので、
Gateway に追加されたモデルはアプリの更新なしで出る。一覧は extension の `/databricks-model-services` が Pi の中で取り（アカウント自身の
Gateway は `--provider databricks` で bridge した sign-in を使う）、token は Pi の外に出ない。各 Gateway が最後に答えた一覧は agent directory の
`gateway-models.json` に provider ごとに保存し、`models.json` はいつもこの保存した一覧とスイッチから作る（まだ答えていない Gateway は同梱の
`models` で代える）。アカウントの切替とスイッチの切り替えは network を使わず、保存した一覧から書く。一覧の取得はアカウントの切替後に最初に
モデルを一覧するとき（と workspace へのサインイン後）に、サインイン済みの Gateway をまとめてバックグラウンドで1回だけ行い、モデル一覧は
それを待たない。取得で `models.json` の Gateway の項目が変わったときだけキャッシュを捨てて `DahliaPiModelsDidChange` を通知し、モデル選択が
読み直す。同じ Gateway の取得が同時に走るときは1つにまとめ、切替やサインインの後に始まった取得があればそれ以前の取得の結果は保存しない。
答えなかった Gateway と、テンプレートで使えるモデルを1つも返さなかった Gateway（system.ai を見られない sign-in、embedding だけの応答など）は
保存した一覧を保つ。
Pi は起動時にしか `models.json` を読まないので、開いているチャットの process が知らないモデルを選ぶと（`set_model` が失敗すると）、ターンを
始める前にそのスレッドを session file から開き直し、そのターンのアカウントと承認方式のまま選び直す。「モデル」タブは保存した一覧を表示し、まだない Gateway と再試行のときだけ取得を待つ。この API は単価・コンテキスト長・推論レベルを返さないため、同梱の
`PiExtension/databricks-models.json` のテンプレートで補う。`templates` は `system.ai.` を除いた名前に glob（`claude-*`、`gpt-*-luna`）で当て、
当たったものをファイル順に重ね、Gateway が返す画像入力、`models` のモデル個別の値の順に上書きする（各段はトップレベルの項目ごとに置き換える）。
テンプレートの経路（`baseUrl` と、Gateway の `supported_api_types` に要る `gatewayApi`）がないモデルと tool を呼べないモデルは出さない。
並びは最初に当たったテンプレート、`models` の順、ID の降順。provider の `baseUrl` に workspace を記録する（各モデルは自分の経路で上書きする）。
Dahlia account は切替時に Server の URL だけを記録し（network 不要）、
モデル一覧の取得時に `/api/v1/models` を `models.json` に変換する。取得に失敗したら直前の一覧を保ち、空の一覧はキャッシュしない。
一覧は account ごとに1つの Pi 起動を同時の呼び出し元すべてで共有し、全員が取り消したときだけ止める。サインイン・サインアウト・
アカウント切替・「モデル」タブの切り替えはキャッシュを捨て、`DahliaPiModelsDidChange` を通知する。それ以前に始まった取得の結果は
保存も返却もせず、その呼び出し元は取得し直す（遅れて終わった古い一覧が新しい一覧を上書きしない）。設定・要約の確認・チャットのモデル選択は
その通知で読み直し、通知の時に表示されていなかったチャットは次に表示されたときに読み直す。画面を開くだけではキャッシュを使い、再試行だけが取得し直す。
チャットのモデル選択はモデルをプロバイダーごとにまとめ、プロバイダー名の下に並べる（workspace のモデル名に付けたホスト名は省く）。
応答性能の選択は、モデルによらず Pi の推論レベル（`none`〜`max`）をすべて並べ、モデルが受け付けないものを選べなくして高さを保つ。
モデルや応答性能を選んでも選択の画面は閉じず、外側のクリックか Esc で閉じる。モデルは `provider/id` で保存し、Codex 時代の
裸のモデル名は ID の末尾一致で移行する。モデルの一覧はアカウント自身の provider を「プロバイダー」に追加した workspace より先に並べるので、
裸の名前の照合も「先頭の利用可能モデル」への切り替えも、利用者が名指ししていない別組織の Gateway を選ばない。見つからなければ保存値を変えず、その要求だけ先頭の利用可能モデルを使う。

追加した workspace のモデルも、アカウント自身の Gateway と同じテンプレートで Unity Catalog の一覧から作り、その provider の項目として
`models.json` に書く（一覧を取るのはサインイン済みの workspace だけ）。`models.json` を書くたびに Gateway の項目をまとめて作り直し、
「プロバイダー」から外したときも書き直すので、外した workspace の項目は（サインアウトに失敗しても）すぐに消え、Gateway 以外の項目（Dahlia account の `dahlia`）は残る。

「エージェント」>「モデル」タブは全アカウントに表示し、Auto review の審査モデルを選べる。
Unity Gateway があるアカウント（Databricks アカウントか、Databricks を追加したアカウント）では、Gateway ごとのモデルも「コネクター」タブと同じくプロバイダーの行の下に折りたたんで並べ、モデルごとのスイッチでオン・オフする。
サブスクリプションと Dahlia account のモデルは対象外。Pi の `models.json` には
モデルごとの有効・無効の項目がなく（`settings.json` の `enabledModels` は起動時の選択と切替の範囲だけで、`get_available_models` からは外さない）、
この有効・無効の設定は `models.json` を編集する。オンのモデルだけを `models.json` に書くので、Pi が知るのもチャット・要約・画像解析が選べるのもそれだけになる。
選択は `provider/id` ごとに app defaults（`agentGatewayModels.<account>`）に記録し、選択のないモデルは既定に従う。既定はオフで、Databricks アカウント
自身の Gateway の、`models` で `onByDefault` を付けたモデル（Claude Haiku 5.5）だけがオン（その Gateway が Haiku を出さないときは先頭のモデル）。オンにしていたモデルを Gateway が出さなくなって自身の Gateway で
オンが1つもなくなるときは、この既定のモデルをオンとして扱い、設定の表示と `models.json` は同じ結果を使う。「プロバイダー」に追加した workspace は
すべてオフで始まる。Databricks アカウントの要約の既定モデルも、保存した設定がなければ同じ Haiku
（`databricks/system.ai.claude-haiku-5-5`）にする。画像解析はモデルを保存せず、一覧にある Haiku を最優先で選び、Haiku をオフにすると次の候補（Luna、なければ画像を受け付ける最初のモデル）を使う。切り替えると保存した一覧から
`models.json` を書き直してキャッシュを捨て、`DahliaPiModelsDidChange` を通知する。チャットにはモデルが要るので、Databricks アカウントは自身の Gateway で最後の1つをオフにできない（追加した workspace は外せるので
数えない。Local・Dahlia account はほかのモデルを持つので制限しない）。
すべてオフにした Gateway は、モデルのない provider として `models.json` に残す（workspace と sign-in のため）。オフにしたモデルが保存されていた要約・チャットは先頭の利用可能モデルを使い、画像解析は保存したモデルが
見つからないとして失敗する。

サインインは extension の `/dahlia-login` が Pi の login を呼ぶ。Pi の extension API に login がないため
非公開の `modelRegistry.runtime` を使い、Pi 更新時に回帰確認する。subscription の利用条件（OpenAI の
Sign in with ChatGPT 登録区分、Anthropic の第三者利用）はライセンスとは別に確認が残る。

## 構造化出力

Pi は最終応答の JSON Schema を持たない。Dahlia は system prompt に schema を含め、schema を強制できる経路では
extension がリクエスト本体に schema 指定を足す。Dahlia がモデル ID で経路を選び（ChatGPT・Claude Pro/Max・
Dahlia・Databricks の GPT・Claude・Gemini）、extension が `ctx.model.api` ごとに形を決める。

- OpenAI Responses: `text.format`（`json_schema`、strict）。schema はそのまま送る。
- Claude Messages: `output_config.format`（`json_schema`）。Pi が付ける `output_config.effort` とマージする。
  Claude が 400 で拒否する `minLength`・`maxLength`・数値範囲・`multipleOf`・`maxItems`・2 以上の `minItems` を外す。
- Gemini（`google-generative-ai`）: `responseMimeType: application/json` と `responseJsonSchema`。対応表にない
  `minLength`・`maxLength`・`pattern` を外す。

Databricks の MLflow 経路（GLM・Kimi）は OpenAI Responses 形式でも strict schema を受け付けないので、prompt の
schema だけで生成する。外した制約は Dahlia 側で守る（要約のタイトルと説明の長さ、タグの正規化、画像解析の件数と
文字数）。Dahlia は返答を JSON object として検証し、型で decode できない返答・拒否・空・`stopReason` が `stop`
以外は生成失敗にする。要約の Markdown fallback には流さない。

## チャットの実行と承認

チャットは作業フォルダで動く（2026-11-11 ユーザー承認）。作業フォルダは「エージェント」>「一般」でアカウントごとに設定し（`piWorkingDirectory.<local またはアカウント ID>`）、
既定は `~/Dahlia`（development profile は `~/Dahlia-Development`）。チャットが自由に書けるので、sandbox の外で実行されるもの（shell の設定、ホームの下に入れた tool と Pi、app の設定）を含むフォルダは指定できない:
ホームフォルダ自身、それを含むフォルダ、`~/Library` とその中、相対 path、Pi を探して起動するときの PATH の folder を含むフォルダ（`pi` を置き換えたり、`node` より先に見つかるコマンドを置いたりできる）は、チャットの起動時に拒否する。`~/Documents` は macOS がアクセス許可を求め、iCloud に同期されうるので使わない。フォルダはなければ作る。
Pi は thread を session file の header の `cwd` で動かすので、Dahlia は thread を開き直す前に header の `cwd` を今の作業フォルダに書き換える。設定の変更は次に起動する chat process から効く。
以前の `Application Support/<profile>/CodexChatWorkspace/<Workspace ID>` は使わず、削除もしない。

Pi に渡す tool は `read`・`ls`・`write`・`edit`・`bash`・`mcp__dahlia__*` と、アカウントに登録した MCP server の tool（2026-11-11 ユーザー承認）。`grep`・`find` は渡さない。
5つの tool の範囲は上の Seatbelt の表のとおりで、範囲内は確認なしで動く。system prompt には SQLite と画像の保存先の path を含め、`sqlite3 -readonly` で参照できる。
実行中のターンでは、直近の tool 名と実行中・完了・失敗・アクセス不可の状態を入力欄の上に表示し、終了結果の受信後はモデルの応答待ちと明示する。引数と出力本文はこの状態表示に含めず、回答本文の受信またはターン終了時に消す。アクセス制限を受けた同じ path の再試行や sandbox の回避をせず、制約を説明して参照可能な情報から続けるよう system prompt で指示する。

| 選択 | read / ls / write / edit / bash | 登録済み MCP の変更操作 |
| --- | --- | --- |
| 常に確認する（Supervised） | Seatbelt の範囲内は確認なし | 毎回ユーザーに確認 |
| AIにより確認する（Auto review） | 同上 | `pi-auto-review` が審査し、許可できない操作・審査失敗はユーザーに確認。critical 判定は実行を拒否 |
| すべての承認をスキップ（Full access） | 同上 | 確認なし |

2026-11-12: MCP の承認を上の3段階にする。Full access でも Seatbelt を解除せず、ファイルやコマンドのアクセス範囲は広がらない。
MCP の tool は Dahlia がその chat に登録した server（Dahlia MCP とアカウントに登録した server。`DAHLIA_PI_MCP_SERVERS`）だけを通し、
それ以外はどの選択でも拒否する。Dahlia MCP の `get`・`query`・`list`・`search` と、gateway MCP の `readOnlyHint` が true の tool は確認・審査なし。
MCP の読み取り結果も untrusted data として扱う。

`pi-auto-review` はコミット `b7822c1a1cdc52513a0d1f5bd342288a005fbdd2` のソース・package metadata・MIT license を
`PiExtension/pi-auto-review` にそのまま同梱する。既定 extension は登録せず、Dahlia の MCP gate が公開された `review` 関数を使う。
審査モデルは「エージェント」>「モデル」>「Auto review」で実行アカウントごとに指定し、`autoReviewModel.<local またはアカウント ID>` に保存する。
空の選択（既定）は審査時点のチャットモデルを使う。変更は起動済みのチャットでも次の審査から効き、`PI_AUTO_REVIEW_MODEL` や Pi 側のモデル指定より優先する。
既定の reasoning effort は high。審査は追加のモデル呼び出しになり、その provider に履歴と予定操作を渡す。任意の triage classifier は使わない。
会議 context と live transcript は審査履歴でも user の承認として扱わない。予定操作が128,000文字を超えた場合も審査せずユーザーに確認し、
既存の承認表示上限を超える操作は許可しない。審査の期限・再試行・取消は upstream に従う。否認・失敗の理由を承認画面で表示する。

承認方式は Dahlia が保持し、extension は MCP の変更操作ごとに bridge で問い合わせる（turn 中の変更も次の呼び出しから効く。不明なら「常に確認する」）。
Pi の session file に承認方式を保存しない。全アカウントで、新しい thread も開き直した thread も「AIにより確認する（Auto review）」を初期選択する。開いているチャットで明示的に選んだ承認方式は保持する。
承認の表示は既存の上限（20 KB など）で切り詰め、取消・停止は未応答の承認を cancel してから abort する。
Codex の web search、`request_user_input` は Pi にないため提供しない。

チャットの追加メニューも「コネクター」と表示し、選択時は元のメニューを残して右側に一覧と設定への入口を開く。
狭い画面では両パネルの幅を調整し、外側クリックまたは Esc で閉じる。

### Unity AI Gateway の MCP

採否は[エージェントによる MCP 経由の外部サービス操作](agent-mcp-operations.md)に従う。
開いているアカウントに、「Dahlia AI」>「モデル」の「プロバイダー」で Databricks の workspace（sign-in）を追加し、「コネクター」タブで
その workspace の MCP server を登録する（2026-11-09 ユーザー承認）。「プロバイダー」には、アカウント自身のモデルのサインインも並べる。モデルの
workspace と MCP の workspace が異なることが多いため、MCP 用の workspace はアカウントとは別にサインインする。Databricks アカウントでは、
モデルと同じアカウント自身の workspace の MCP も選べ、その server は `auth.provider` にアカウントの bridged provider（`databricks`）を指定して
アカウントの token を使う。一覧も `/databricks-mcp-services <URL> --provider databricks` でその token で取り、ここではサインインもサインアウトも
しない。この workspace は最初の server と一緒に保存し、最後の server を外すと消す。登録は Local Account・Databricks
アカウント・Dahlia account のどれでもでき、アカウントごとに app defaults（`agentMCPs.<local またはアカウント ID>`）に保存する。
Unity Gateway の MCP は登録の操作を要さない（2026-11-09 ユーザー承認）。「コネクター」タブは、アカウント自身の workspace と「プロバイダー」で
追加した Databricks を折りたたみ可能な見出しとして並べ、その下に MCP service を2列のカードで表示する。一覧は中央の設定カラムに収め、カードには名前と API の `comment` を表示し、検索は説明も対象にする。各 MCP service のカード右上にトグルを置き、有効な MCP だけ、その左に小型の円形の認証表示と処理中のキャンセルを表示する。プロバイダーのサインインは「モデル」の「プロバイダー」で行う。オンにすると server を登録し、オフにすると外す。
各 provider のすべてのサービスカードの後に「MCP サーバーを追加」カードを置く。`main.default.notion` のような完全名を入力すると有効なカードとして追加し、無効化後も一覧に残す。追加用カードは常に最後に表示する。

並べる MCP service は、その workspace の Unity AI Gateway が sign-in に見せるもの（`system.ai` の下で状態が ACTIVE のもの。
`GET /api/2.1/unity-catalog/mcp-services`）と、登録済みの service である。最後に取った一覧を設定に残して展開したときに先に示し、展開する
たびに取り直す。取り直しに失敗しても前の一覧を残し、失敗を示す。一覧は token を持つ Pi が control process の `/databricks-mcp-services <workspace URL>`
で取り、Dahlia には名前と `comment` を返す。説明も最後の一覧とともに保存し、取得失敗時は保持する。`system.ai` 以外の schema は自動列挙せず、完全名で登録した有効な service だけを個別の GET API で取得する。server 名は tool
名の接頭辞（`mcp__<name>__`）になるので、英小文字・数字・`_` の40文字までとし、アカウントの中で重複させず、`dahlia` を使わない。既定は
service 名の最後の部分（`system.ai.github` なら `github`）で、重複するときは番号を付ける。名前は自動で割り当て、設定からの変更は提供しない。同じアカウントで複数の workspace を登録できる。

sign-in は workspace ごとに1つで、その workspace の server すべてが共有する。どの server を使っても同じ refresh token が更新される。
Databricks provider（`PiExtension/databricks-provider.ts`）が sign-in を provider として登録する。provider 自体はモデルを持たず、
モデルは Dahlia が `models.json` に書く（Gateway の 3 つの API を持つ）。provider の ID は workspace の
host（port があれば `:<port>` を付ける）で、同じ workspace をもう一度追加するとサインインし直し、provider は1つのまま使う。アカウント自身の workspace は追加させない。チャットはドットで Pi 自身の provider と区別するので、ホスト名にドットのない URL も追加させない。設定ではどの Databricks の provider も「Unity Gateway (ホスト名)」と1行で示し、表示名は持たない（2026-11-09 ユーザー承認）。
この provider の `auth.oauth` が workspace の `/oidc/v1/authorize`・`/oidc/v1/token` に対して PKCE の認可コードフローと refresh を行い、
Pi がその credential を agent directory の `auth.json` に保存し、ロックの中で refresh する。credential には token と一緒に workspace の
origin と client を保存するので、どの process も provider の ID だけで refresh できる。`dahlia.ts` がどの process でも
`registerDatabricksProviders` を呼び、起動時に `mcp.json` の `auth.provider` と `models.json` の provider のうちドットを含む ID
（Pi 自身の provider の ID にはない）を provider として登録する。Dahlia は provider の一覧を環境変数で渡さない。`/databricks-login`・
`/databricks-mcp-services`・`/databricks-model-services` は `dahlia.ts` の control 用の分岐が import して登録する。
client の既定は Databricks CLI の公開 client `databricks-cli`（redirect は `http://localhost:<8020〜8040>`）で、Pi が自身の
Client ID Metadata Document を公開したらそれに置き換える（2026-11-09 ユーザー承認）。scope は `ai-gateway unity-catalog offline_access`（MCP の呼び出しに `ai-gateway`、MCP service の一覧が Unity Catalog の API なので
`unity-catalog`。モデルの呼び出しと一覧も同じ scope で足りる。2026-11-09 ユーザー承認）。一覧が拒まれたときは、Databricks が返す `error_code` と `message` をエラーに含める。
client は利用者に選ばせず、databricks-cli に固定する（2026-11-09 ユーザー承認）。組織が登録した client（Isaac など）が要るときのため、
extension の `/databricks-login` は `--client-id`・`--redirect-url`・`--scopes` も
受け付ける。`resource` は送らない。Pi の MCP OAuth（`mcp-auth.json`）は server 名と URL ごとに credential を分けるので使わない。

sign-in は利用者の操作でだけ始める。workspace を登録するときと、設定の「サインイン」で、control process の
`/databricks-login <workspace URL> [--client-id <id>] [--redirect-url <url>] [--scopes <a,b>]` を動かす。このコマンドはその場で provider を
登録してから Pi の login を呼び（`/dahlia-login` と同じ非公開 API）、認可 URL を `databricks:auth_url` で知らせ、Dahlia がブラウザで開く。
このコマンドは control の process にだけ登録する。Pi は refresh に失敗した server を「needs sign-in」にしてブラウザを自分では開かないので、
チャットは Pi の通知（接続後の notice と、sign-in を求める tool の失敗）を thread の process ごとに覚え、turn のたびに「設定でサインインし直す」
よう表示する。Pi は `auth.provider` の server を sign-in の後に自動で接続し直さないため、sign-in が終わるとそのアカウントのチャットの process
を閉じ、次の turn で開き直す。設定は `auth.json` の key だけを読んでサインイン済みかを示す。server を削除しても sign-in は残し、workspace を削除すると、その server もまとめて消してから `/dahlia-logout <provider>` で credential を消す（Pi は provider が登録されていなくても消せる。Pi が動かず消せなくても登録は消し、失敗を示す）。MCP の裏にある
サービスの接続（GitHub など、利用者ごとの OAuth）へのサインインは、「コネクター」タブの各 service のカード右上のサインインアイコンで始める。
Databricks SQL・Sandbox・Genie One・Web Search（`system.ai.dbsql`・`sandbox`・`genie_one_mcp`・`web_search`）は workspace のサインインを使うので、追加認証の表示と状態確認の対象にしない。接続先の認証状態は、有効化している追加認証対象の MCP だけを対象に、Beta の `GET /api/2.1/unity-catalog/mcp-services/<service>/user-credentials` で一覧取得時・有効化時・サインイン完了後に確認する（`--enabled` で対象の service 名だけを Pi に渡す）。`provisioning_info.state` が `ACTIVE` のときだけクリック操作のない円形の緑のチェックバッジを表示し、それ以外の状態または `NOT_FOUND` はサインインが必要として示す。API 非対応・権限不足・通信失敗は未確認として表示する。未認証・未確認のときは円形のサインインボタンを表示し、無効な MCP には認証表示を出さない。無効化したら進行中のサインインも取り消す。状態は Pi から列挙結果に添え、token や有効期限は渡さず、アプリ終了後に再利用する設定にも保存しない。トグルはその MCP の利用設定を表し、認証状態とは独立する。
control process の `/databricks-connection-login <workspace URL> <service>` が、その service の URL を `resource`（RFC 8707）
に付けた認可要求をブラウザで開き、workspace が接続のサインインを済ませてから返す認可コードは token に交換しない（workspace の sign-in は
そのまま）。終わるとそのアカウントのチャットの process を閉じ、次の turn で接続し直す。MCP が返すリンクからのサインインもそのまま使える。

チャットの process を起動するたびに、Dahlia は登録した server を `mcp.json`（0600）に `<workspace>/ai-gateway/mcp-services/system.ai.<name>`
の `url`・`exposure: "direct"`・`auth: { provider: "<sign-in の provider>" }` だけで書く（登録がなければ空）。Pi は `mcp.json` を起動時に
だけ読むので、登録の変更はその後に起動する chat process から効く。開いている thread の process は、閉じるまで前の設定のまま動く（遅れは
ユーザーが許容。2026-11-07）。`--tools`・`DAHLIA_PI_MCP_SERVERS` は process ごとに同じ時点の設定から作るので、
別の thread が先に書いた新しい `mcp.json` を読んでも、その process で使える MCP は起動時の設定の範囲に留まる。

履歴の正本は Pi の session file（実行アカウントの agent directory の `sessions/<Workspace ID>`）。モデルと同じくアカウントに属し、Workspace を別のアカウントへ移しても移さない。移動先では、そのアカウントでの履歴だけを表示する。Codex の rollout は表示せず、
ファイルは削除しない。

チャット入力の先頭で `/` を入力すると、Pi の `get_commands` が返す拡張コマンド・プロンプトテンプレート・スキルを名前と説明で絞り込む。候補は最大50件、幅は最大320ptとし、入力欄の上を優先して表示する。上に収まらないときは画面内に収まる側へ配置し、縦はスクロール可能とする。クリックまたは ↑↓ と Tab／Enter で補完し、Esc・外側クリック・引数の入力で閉じる。補完だけでは送信しない。応答の生成中に送信したスラッシュコマンドは追加指示用の `steer` に流さず、現在の turn の終了処理後に `prompt` で実行する。待機中のコマンドは入力欄の上に表示し、キャンセルできる。後続の入力もキューの順序を保つ。`/mcp` などが RPC の通知で返す結果はチャット内に通知の種類に応じたアイコン付きのオレンジの1行見出しと、展開・折りたたみ可能な等幅テキストの詳細として表示する。見出しは改行を空白に置き換え、利用できる横幅まで表示する。詳細は初期状態で折りたたみ、展開すると改行と全文を表示する。通知は表示中の会話に残すが、Pi の履歴に保存されないため会話を開き直したときには復元しない。agent run を起こさないコマンドも結果通知の後で完了する。TUI 専用の `/settings` などは候補に含めない。コマンドは Pi が先頭で解釈できるよう閲覧中の会議・Project の自動 context を付けず、明示的に添付した会議参照はコマンドの後ろに付ける。この入力補完は macOS の Local／Server Account 共通で、Private Web・Electron の Server AI や MCP の操作は対象外。

## 検証

fake transport で RPC の順序・失敗・取消を、`test-pi-extension.py` で実 Pi とローカル gateway の
token bridge（Anthropic・Gemini・OpenAI の各 API と redirect 先に付かないこと）・strict schema・読み書きの範囲・MCP の承認と、ローカルの
OIDC での MCP の sign-in（databricks-cli と、Redirect URL を登録した client）・token・refresh（`auth.provider` のない MCP に付かないこと）を確認する。Pi 更新時は RPC event、extension API、
login の非公開 API、`text.format` の payload 形を回帰確認する。`test-pi-extension.py` は5つの tool を `pi.sb` の中で動かし、sign-in と秘密の環境変数が読めないこと、symlink で外に書けないことも確かめる。
sandbox の境界（書き込み・ホームと agent directory と一時フォルダの読み取り・symlink・Unix socket）は `PiSandboxTests` が実際の `sandbox-exec` で確かめる。
