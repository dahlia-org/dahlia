# 内蔵 Pi runtime

対象: Desktop の要約・画像解析・画像選別・チャット。採択: 2026-11-06。ユーザー承認済み。
承認方式は[チャットの承認](chat-approval.md)、実行アカウントは[アカウント](accounts.md#実行アカウントの-context)を参照する。

## Pi の実行ファイル

Dahlia は Pi を同梱せず、利用者がインストールした `pi` を使う（2026-11-07 ユーザー承認）。
実行する `pi` は、「エージェント」>「詳細設定」>「一般」の「アプリ管理下の Pi を使う」で切り替える（2026-11-12 ユーザー承認）。
オフが既定で、PATH 上の `pi` を探索して表示・利用する。オンでは Dahlia がインストールした `bin/pi` のパスを表示・利用する。
実行ファイルのパスやコマンド名は手入力させない。選択はアプリのアカウント（`local`）の設定として保存し、
Dahlia がインストールする Pi はアプリプロファイルごとに 1 つ置く。旧パス設定がその `bin/pi` を指していた場合はオンを引き継ぎ、
それ以外の旧設定は PATH 探索に切り替える。明示的に切り替えたトグルは旧設定より優先する。
Finder／アプリランチャーから開いた場合は、起動時の PATH に Homebrew（`/opt/homebrew/bin`・`/opt/homebrew/sbin`・`/usr/local/bin`・`/usr/local/sbin`）、`~/.local/bin`・`~/.bun/bin`・`~/bin`・`~/Library/pnpm`・`~/.volta/bin`・`~/.npm-global/bin`・`/opt/homebrew/opt/libpq/bin` を補助探索先として加える。シェルや `.zshrc` などの起動スクリプトは実行しない。
nvm は `~/.nvm/versions/node/v*/bin`（`NVM_DIR` が設定されていればその配下）を、インストール済みのバージョン番号の降順で探索する。既存の PATH を優先し、nvm の default alias は評価しない。Pi の実行時は、見つけた Pi 自身のディレクトリを PATH の先頭に置き、同じバージョンの Node.js を利用する。探索・実行・パッケージ操作とファイルアクセス制限の検証は共通の探索先を使う。
アカウントが「環境変数」で PATH や NVM_DIR を設定していれば、シークレットを含め、起動する Pi と同じ値で探索する。設定画面の「使用するコマンド」はこれらの設定変更後に更新する。
選択した Pi が見つからないときは `piCommandNotFound` で失敗し、別の Pi にはフォールバックせず、要約・画像解析は未サインインと同じく保留にする。
切り替えは以後起動する Pi process に適用する。

セットアップツアーは最初の手順を表示する前に、アカウントで使う Pi を確認する。利用できる Pi がない場合は、モデルプロバイダー設定より先に
アプリ管理下の Pi のインストールを案内する。既にアプリ管理下にインストール済みならそれを選択でき、インストールまたは選択の完了時に
そのアカウントの「アプリ管理下の Pi を使う」をオンにする。後回しで続行でき、失敗・キャンセル時は選択を変えない。

オンのとき、未インストールなら「Pi をインストール」、インストール済みなら「アップデートを確認」を出す。
インストール・更新中にオフへ切り替えても、その選択は保持する。インストールも更新もボタンを押したときだけ行う。
入れ方は Pi 公式のインストーラー（`pi.dev/install.sh`）に倣い、Node.js と npm の代わりに Bun を使う（2026-11-26 ユーザー承認）。
macOS には JavaScript runtime が標準で入っておらず、Pi の release バイナリも Bun で作られている。npm パッケージは Pi のモジュールを
bundle せずに持つため、拡張（`pi-mcp-elicitation`）から Pi の MCP runtime を使える。単体バイナリはそれができない。

- Bun（`PiInstaller.bunVersion`、Pi の release バイナリと同じ版）は GitHub API の asset URL（`Accept: application/octet-stream`。
  github.com の `browser_download_url` は HTTP 504 を返したことがある）から取得し、コードに固定した SHA-256 で確かめて
  `BUN_INSTALL`（`Application Support/<profile>/bun`）の `bin/bun` に置く。`~/.dahlia` は利用者が読み書きするデータ（Pi のホーム・エージェント）の置き場なので、入れ替えられる実行環境は置かない。利用者の Node.js・npm・nvm は使わない。
- 版は取得先のレジストリの `dist-tags.latest` で決め、その版の `package.json`（overrides を含む）と `package-lock.json` を pi.dev の `api/installer/releases/<版>` から取る。
  pi.dev の latest は、プロキシのレジストリがまだ通さない新しい版のことがある（公開翌日の版に HTTP 403 を返した）。
  Bun はロックファイルの tarball URL をそのまま取りに行き、npm のように設定したレジストリへ読み替えないので、`resolved` だけを除き、
  版と integrity はロックファイルのまま、設定したレジストリから取る。
- レジストリは既定で `https://npm-proxy.cloud.databricks.com/` を使い、UI にはこの URL を表示しない（2026-11-26 ユーザー依頼）。
  別のレジストリ（社内プロキシなど）は上級者向けの設定として、「Pi をインストール」「アップデートを確認」の横の「レジストリを設定」で開くアプリ内モーダルの「npm レジストリ」（`piNpmRegistry.local`）で指定し、
  変えるまで保持する。http(s) の URL だけを受け付け、Bun の global folder の `.npmrc`（`registry=<URL>`）に書く。Bun はこれを
  Dahlia のインストールでも `pi update` の `bun install -g` でも `~/.npmrc` より優先して読む。「アップデートを確認」は実行前に今の設定で `.npmrc` を書き直す。
- Bun の global folder（`bun/install/global`）を作業用 folder で作り直し、`bun install --ignore-scripts --production` で入れる。
  パッケージの `bin` の `pi` を Bun で `--version` 実行し、版と一致したら入れ替え、`bun install -g` と同じく `bun/bin/pi` からその entry point への
  相対リンクを作る。失敗したら今の Pi を残す。Dahlia のインストールは `bun/.lock` の flock で1つずつ行う。
- 配置は `bun install -g` のとおりで、独自の起動スクリプトは持たない。アプリ管理下の Pi は `bun/bin/pi`。entry point は
  `#!/usr/bin/env node` で macOS には Node がないので、Dahlia は `bun/bin/bun bun/bin/pi …` で起動し、`BUN_INSTALL` を渡す
  （`PATH` の先頭は実行ファイルの folder の `bun/bin`）。`bun/bin` に `node` は置かない（PATH に入れた利用者の Node を隠すため）。Pi は Bun の global install として自分を認識するので、`pi update` は標準どおり
  `bun install -g --ignore-scripts` で global folder を更新する。ただし `pi update` は版を pi.dev の latest で決めるので、プロキシが
  まだ通さない版では失敗する。そのため「アップデートを確認」は `pi update` を使わず、インストールと同じくレジストリの `dist-tags.latest` を読み、
  入っている版より新しいときだけ `bun install -g --ignore-scripts --minimum-release-age=0 <package>@<版>` を `bun/.lock` の下で実行する。
  レジストリの版が入っている版以下なら何もしない（下げない）。Dahlia は版を管理しない。
  更新は global folder をその場で書き換えるので、動いている Pi は次の起動から新しい版になる。
- `bun` folder は Application Support の中なので、チャットの sandbox からは読み書きできない。
- 以前の Dahlia が `Application Support/<profile>/bin/pi` に入れた単体バイナリは、`bun/bin/pi` が入るまでアプリ管理下の Pi として使い、削除しない。

PATH 上の `pi`（npm・Homebrew など）は利用者のものとして更新しない。

インストール失敗は release 取得、download（npm パッケージの取得を含む）、検証、展開、保存・切替の段階と理由を日英で表示し、HTTP エラーには status code を添える。
GitHub の 429、または rate limit header を持つ 403 はアクセス制限として案内する。Settings・セットアップ・CLI は同じ installer で
失敗を一度だけ匿名診断へ渡す。Sentry へ渡す固定カテゴリと tag は [Telemetry policy](../../telemetry.md) に従い、キャンセルは記録しない。

`Dahlia --install-pi [version]` は app を開かずに同じ手順で版を入れる（版を省くと latest）。ターミナルで使う人は、Bun の
公式インストーラーが `~/.bun` で求めるのと同じく、shell 設定で `BUN_INSTALL` を `bun` folder にして `bun/bin` を `PATH` に入れる。
`pi` の直接実行には Node（22.19 以上）が要り、なければ `bun "$BUN_INSTALL/bin/pi"` で動かす。更新は `pi update` で行う。
Dahlia は利用者の shell 設定や `~/.pi` には書かない。版は固定しないため、`dahlia.ts` が使う RPC と extension API の互換は
Pi の更新時に `test-pi-extension.py` で確かめる。ユーザーの `~/.pi` は使わない。

利用者は「エージェント」>「一般」の「環境変数」で、アカウントのすべての Pi process（要約・チャット・control）に環境変数を足せる
（2026-11-09 ユーザー承認。`piLaunch.local`）。Dahlia が設定する変数より先に入れるので、Dahlia の指定
（agent directory・`PI_OFFLINE` など）が勝つ。秘密にした値は Keychain（`piEnvironment.<profile>.local.<変数 ID>`）に置き、
起動のたびに読む。設定画面には戻さない。変数名が環境変数として不正なもの、値のないものは渡さない。起動引数は足させない。

## Process と境界

Pi の agent directory は `~/.dahlia/pi`（0700）。development profile は自分のデータの folder の `pi` を使い、production のサインインを共有しない。中身は Pi の形式なので名前に Pi を含める。別の実行環境を足すときは `~/.dahlia/<実行環境名>/` に置き、自己学習した skill は `pi/skills` を正本のまま動かさず、その実行環境の home から symlink で参照する（2026-11-26 ユーザー決定）。エージェント（人格）の home は隣の `~/.dahlia/agents/` に置く（[always-on](always-on-agent.md)）。`Application Support/Dahlia/accounts/<アカウント>/pi` は移行元としてだけ読む。ユーザーの `~/.pi` は使わない。
アカウント別の設定キーの接尾辞と DB の `accountID` は `local`（`AppAccount.key`）。`PI_OFFLINE`・`PI_SKIP_VERSION_CHECK`・`PI_TELEMETRY=0` と、
extension・context file・theme・project trust の自動読込を無効化して起動する。チャットでは標準 skill、アカウントの `pi/skills` に保存した skill、追加したパッケージの skill・prompt template を読み込む（2026-11-12 ユーザー承認）。要約・画像解析・通常の control は skill・prompt template も無効にする。「スキル」タブ専用の一覧プロセスは同じ resource loader で読み込み、モデル・MCP・tool を実行せず `get_commands` の認識結果を一覧にする。スキル名と最大2行の説明を表示し、保存先はフォルダを開く操作に使う。詳細はアプリ内モーダルで説明と SKILL.md を表示し、ファイル読込と Markdown 解析は MainActor 外で行う。追加・変更は新しいチャットプロセスから反映する。
内蔵 `skill-creator` はチャットから Pi 向け skill の作成・更新・検証を支援する。`/skill:skill-creator <依頼>` でも呼び出せる。
保存先は system prompt に渡した現在のアカウントの `pi/skills/<skill-name>/SKILL.md` とし、アカウント内の Workspace 間で共有する。
組み込み・パッケージの skill は直接変更せず、カスタマイズは別名の account skill として保存する。保存後は新しいチャット process で利用でき、
設定の「スキル」の再読込で認識を確認できる。account skill の編集・削除も次の process から反映する。すべての変更は `skill_manage` に集約し、ファイル道具からの直接変更は許可しない。
作成方針は [Codex Skill Creator](https://github.com/openai/skills/tree/main/skills/.system/skill-creator) の段階的な情報開示と
[Claude Code Skill Creator](https://github.com/anthropics/skills/tree/main/skills/skill-creator) の試行・評価・改善を参考にし、
保存先・呼出形式・利用可能な tool・承認は Dahlia の Pi runtime に合わせる。

「エージェント」>「詳細設定」>「プラグイン」から npm source または Git URL を Pi の `install`・`remove` で管理し、同じアカウントの `settings.json` を一覧の正本にする。変更は次に開始するチャット process から適用する。
パッケージ操作はアカウントの Pi 選択と環境変数を使い、`PI_CODING_AGENT_DIR` は Dahlia のアカウント directory に固定する。`~/.pi` や project の設定には追加しない。拡張コードは無効のままとし、インストール元は利用者が信頼できるものを指定する。
プラグインは「コネクタ」と同じカードで一覧し、カードのスイッチでインストール・アンインストールする。新規追加は「プラグインを追加」カードから専用のアプリ内モーダルを開き、npm source または Git URL を入力する。モーダルにはカタログへのリンクを表示し、インストール成功時に閉じる。Dahlia に同梱した `pi-auto-review` は、スイッチをオンに固定したカードとして先頭に表示し、オフにできない（2026-11-27 ユーザー承認）。そのカードの設定ボタンから、審査モデルとトリアージの設定をアプリ内モーダルで開く。以前のリリースでインストールした `pi-auto-review` の登録は一覧に出さず、使わない。同じ旧 source の新規インストールは、内蔵済みであることを案内して拒否する。
おすすめの `pi-web-access` も同じくオフのカードとして表示する（2026-11-19 ユーザー依頼）。インストール元はバージョンを固定した npm source（`AgentWebAccessSettings.packageSource`）で、依存パッケージを npm レジストリから取得する。
インストール済みなら、Dahlia は対話チャットにだけ upstream の standalone MCP worker（`<アカウントの pi>/npm/node_modules/pi-web-access/dist/mcp-cli.js`）を `dahlia_web_access` server として登録し、`mcp__dahlia_web_access__web_search`・`source_check`・`fetch_content`・`get_search_content` を利用可能にする。Pi 本体へプラグインの extension は読み込まず、予定実行とバックグラウンドレビューでは worker を登録しない。
worker は専用の `web-access.sb` で実行し、子プロセスの作成は許可しない（GitHub clone・gh API・動画の外部 CLI などは使えない）。読み取りは OS・実行用コード・同じアカウントの npm package と `web-search.json`、書き込みはアカウント内の `web-access-runtime` に限る。チャットの作業フォルダ・追加のファイル許可は渡さず、ホストの CLI 設定・ブラウザの Cookie・Keychain は許可しない。環境は空から PATH・専用 HOME/TMPDIR・アカウントの agent directory だけを渡し、API キーはそのアカウントの設定ファイルから読む。worker の Node.js は Pi とは別に PATH から解決し、version manager の shim からも実際の interpreter を確認する（管理版 Pi も同じ経路）。Node.js がなければインストールを案内するエラーにする。worker は Pi の MCP lifecycle に従って停止・キャンセルされる。
Dahlia の extension は builtin MCP 由来のこの server の tool を通し、http・https 以外の URL と `auth` を拒否する。URL の検査とは独立に、各ファイルの open と子プロセスには kernel の sandbox 境界が適用される。ネットワークはチャットのコマンドと同じく到達できる。
`pi-mcp-elicitation` は Dahlia が `PiExtension/pi-mcp-elicitation` に同梱する独立した Pi package で、既定で導入済みとし、
カードはスイッチをオンのまま固定して表示する（オフにはできない。2026-11-26 ユーザー依頼）。Pi の `settings.json` には登録しない。
対話チャットは常に `builtin:mcp` の代わりに Dahlia の確認 adapter を渡す `dahlia-mcp.ts` を `-e` で読み込み、`DAHLIA_PI_MCP_EXTENSION` で Dahlia の extension に MCP tool の出所として伝える。独立 package の既定 UI は Pi の `confirm` とし、host は factory へ確認 UI を注入できる。
プラグインは Pi の `createMcpExtension` に transport を包んで渡し、`initialize` で `elicitation.url` を宣言する（MCP 2025-11-25 の URL mode elicitation。form mode は宣言しない）。
`elicitation/create` と、URLElicitationRequiredError（`-32042`）で失敗した request の両方で、ページの host と URL 全体を Pi の `confirm` で見せ、同意したときだけブラウザーで開く。
自動では開かない。ブラウザーの起動に失敗した場合は `elicitation/create` を cancel し、`-32042` は元の error を返す。
https（loopback は http も可）以外の URL は確認せずに断る。`-32042` の request は、ページを終えたかを2回目の `confirm` で確かめてから新しい request ID で送り直し、
利用者が続けなければ元のエラーを返す。待つあいだは progress 通知で Pi の request timeout を延ばす。UI のない process では常に断る。
Pi の MCP runtime（npm パッケージの `dist/extensions/mcp/runtime.js`）が見つからない Pi（単体バイナリ）では、Pi の MCP をそのまま使い、elicitation が無効だと通知する。
Dahlia の adapter は確認ごとの ID で開始と取り消しを対応付け、取り消した確認だけを承認カードから除く。承認カード（「続行」「キャンセル」）には承認方式（Auto review・フルアクセス）にかかわらず利用者が答える。予定実行・バックグラウンド処理・ターン外の確認は断る。
設定は upstream の `web-search.json`（アカウントの agent directory。チャットのコマンドからは読めない）を正本にし、カードの設定ボタンのモーダルで Web 検索の有効化と主要な検索プロバイダーの API キーを編集する。保存時は `tools.webSearch.enabled`・`tools.sourceCheck.enabled` の個別指定を解除して両方を Web 検索のスイッチに揃え、それ以外の項目は保持する。
upstream は `webSearch.enabled` がないと Web 検索をオンにするが Dahlia の既定はオフで、読み込む前に未設定なら `false` を書く。変更は新しいチャットから効く。

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
| 現在のアカウントの `pi/skills` | ファイル道具には読み取り専用。変更は `skill_manage` からアプリのサービスを通す（[自己学習](pi-self-learning.md)）。Pi が再利用する skill の保存先。認証・設定・他アカウントへのリンク先は許可しない。保存先への symlink 作成・移動を拒否し、skill 探索でも symlink を除外する。保存先またはその配下が実効 PATH に含まれる設定は、全 Pi モードとパッケージ操作の起動前に拒否する |
| Dahlia の preset skill、アカウントの Pi directory の `npm`・`git` 配下（インストール済みパッケージ）、画像の保存先（`FileStore`）、app の SQLite（`dahlia.sqlite` と `-wal`・`-shm`） | 読み取りだけ（画像と SQLite はデバッグ用） |
| Dahlia の Application Support のそれ以外、agent directory、エージェントの home（録音、backup、`~/.dahlia/pi`、`~/.dahlia/agents`。development build からは production のものも） | 読み書き不可（作業フォルダがこれを含んでいても）。エージェントの Pi には、自分の home だけを作業フォルダとして開く |
| システムと全ユーザー向けの tool（`/System`・`/usr`・`/bin`・`/sbin`・`/Library/Developer`・`/Applications`・`/opt`・`/private/etc` など、`pi.sb` に名前で列挙） | 読み取りだけ。ただし local service の data と設定（`/opt/homebrew`・`/usr/local` の `var` と `etc`）は不可 |
| セキュリティ設定で追加したファイル・フォルダ | アカウントごと・この Mac のチャットだけに、読み取りのみ／読み書きを追加。ファイルはその実体だけ、フォルダは配下を含む。既存の保護対象への例外にはならない |
| それ以外すべて（ホーム、`/Volumes`、利用者の一時フォルダと cache など） | 追加の許可がなければ読み書き不可（metadata は読める） |
| IP の network | すべて許可（当面）。この Mac 自身の service（ブラウザの debug port、ローカルの DB）にも届く。Seatbelt の address の条件は IPv4-mapped IPv6（`::ffff:127.0.0.1`）を localhost として扱わないので、localhost だけを確実に閉じることはできない |
| Unix socket | DNS（mDNSResponder）だけ。ssh-agent、Docker、Dahlia の broker には届かない |

画像の保存先と SQLite は全 Workspace・全アカウントの内容を含む。Dahlia MCP のアカウント境界（PRODUCT.md の T4）の外にある、デバッグ用の読み取りとしてユーザーが承認した例外である。
network は開いているので、読める内容は外部に送信できる。

extension は `read`・`ls`・`write`・`edit`・`bash` を Pi の `create*Tool` で登録し直す。file 操作（読み取り・一覧・書き込み・folder の作成・画像の判定）は `sandbox-exec` の中の `cat`・`ls`・`mkdir`・`head` で行い、
`bash` は `spawnHook` でコマンドを包む。path は開くときに kernel が判定するので、コマンドが作った symlink や検査後の差し替えで範囲の外に出ることはない。extension は path を検査しない。
「セキュリティ」タブは作業フォルダに加え、スキル保存先・一時フォルダ・標準 skill・パッケージの既定のアクセス権と、優先する保護対象の例外を表示する。画像・SQLite は「Dahlia データ」、OS の読み取り許可は「システムフォルダ」に折りたたむ。Dahlia データは画像フォルダと DB 関連ファイルだけを許可し、認証情報や設定を含む親フォルダ全体は許可しない。

sandbox の引数は Dahlia が `DAHLIA_PI_SANDBOX` で渡す。引数がないとき、または呼ばれる tool が Pi の built-in のまま（extension の登録が置き換えていない）のときは、5つの tool を拒否する。
`HOME` と `TMPDIR` は追加の許可にかかわらず専用の一時フォルダを指す。`~/.desk.toml` などを追加した場合は絶対パス（必要なら `DESK_CONFIG` などの環境変数）で参照する。追加していないホーム内の設定・tool（uv・nvm・pyenv など）は読めない。sandbox の中の環境からは、利用者が「環境変数」で秘密にした変数（`DAHLIA_PI_SANDBOX_HIDDEN_ENV`）と、認証値を含みうる MCP の接続設定（`DAHLIA_PI_MCP_CONFIG`）を除く。
作業フォルダはチャットが書けるので、Pi がそこから設定を読まないことが前提になる。Pi は `--no-approve` で project の設定（`.pi/mcp.json` など）を無視する。
Dahlia MCP は Pi の子のままで、コマンドは SQLite に書けず MCP にも届かないので、Dahlia のデータの変更は上記の承認方式に従う MCP の tool だけが行う。
Pi の codemode（未有効）の script は Pi の process 内の QuickJS で動き、file system も network も持たない。script が呼ぶ tool には同じ制限（Seatbelt と MCP の承認）が掛かる。

- 要約・画像解析・画像選別・モデル一覧・サインインは操作ごとに `pi --mode rpc --no-session --no-tools` を起動し、終了・取消・610秒期限で閉じる。同じモデルへの自動再送はしない。取消・期限切れでは終了済みの process を後始末のために起動しない。要約・画像解析・画像選別は、利用者がフォールバックモデルを設定した場合だけ、生成失敗時にそのモデルを1回試す。
- チャットは turn の開始時に thread ごとに1 process を起動し、turn 後はチャット画面が thread を開いている間だけ残す。履歴の表示や新規 thread の作成では起動しない。process が終了していれば次の turn で session file から開き直す。スラッシュ候補の取得は既存 process を使い、なければ同じチャット用 resource を読む `--no-session` の一時 process を取得完了・失敗・取消で閉じる。
- OpenAI / Anthropic のサインイン・サインアウトでは Pi を止めず、プロバイダーアカウントの追加・削除と同じくモデル一覧を捨ててチャットを開き直す（[Provider](#provider)）。
- stdout の1行は 4 MiB（送った最大行の分を加える）までとし、超えた行は改行まで捨てて読み続ける。Pi の `turn_end`・`agent_end` は run のメッセージを画像ごと繰り返すが、Dahlia は読まない。
- prompt、画像、文字起こし、チャット、生成結果、request / response body を log や Sentry に送らない（[Telemetry policy](../../telemetry.md)）。取消・未サインイン・Pi 未検出（`piCommandNotFound`）は期待状態として扱う。
- アプリ終了時は新しい Pi process の起動を拒否し、stdin を閉じ、猶予後に SIGTERM、さらに SIGKILL で止め、stdio を drain して reap してから終了する。
- 要約は一時的な作業フォルダ（temporary cwd）で動き、生成の結果にかかわらず削除する。
- 画像非対応・能力不明のモデルには画像を渡さず、テキストで続ける。
- Dahlia は RPC の extension UI（`ctx.ui.input("dahlia:<method>")`）でだけ extension と通信する。token は要求ごとに stdin で渡し、config・環境変数・log に残さない。
- Databricks の接続と Dahlia account の provider（`DAHLIA_PI_BRIDGED_PROVIDERS`）は、extension が pi-ai の `createProvider` で認証だけを持つ provider として登録し、使うたびに bridge の `token` で起動時の接続 ID に結び付いた credential を解決する。RPC の初期化応答までに設定が変わった起動は閉じてやり直す。別の接続へ切り替わった古い要求は拒否し、モデル一覧の取得先と credential も同じ接続に固定する。切り替え前に始めた一覧は新しい設定へ保存しない（モデルは `models.json` を重ねる。session 開始前の利用可否の確認には要求に使わない仮の値を返す）。`models.json` に key は書かない。
- Unity AI Gateway の sign-in は、extension が OAuth の provider として登録する（[Unity AI Gateway の MCP](#unity-ai-gateway-の-mcp)）。モデルは Dahlia が `models.json` に書く。MCP の接続設定は `auth.provider` でその credential を要求ごとに使う（Pi の文書にない項目で、Pi 更新時に回帰確認する）。

### stdio

- 読み取りは、未完の reader があり完全行の手持ちがない場合だけ最大 64 KiB の DispatchIO read を開始する。lowWater 1 で部分配送を即時解析し、window ごとの lock-protected Data relay と単一 consumer で FIFO を保つ。callback ごとの Task や callback 数で上限を決める stream は使わない。
- 完全行を渡した後や後続の完全行を保持中は新しい window を開始せず、consumer 停止時は OS pipe に backpressure を返す。
- stderr は独立して drain し、末尾16 KiB だけをメモリに保持する。
- 壊れた JSONL は読み飛ばさず、protocol failure とする。EOF、process 終了、protocol failure では待機中の全 request・turn・login waiter と subscriber を error で完了し、再起動は close の後だけ行う。
- 通常 request の cancel / timeout は該当 waiter だけを完了し、接続と他の turn を維持する。期限は [AI timeout](../shared/ai-timeouts.md) に従う。

## Provider

アプリのアカウントは OpenAI と Anthropic に別々にサインインでき、サインイン済みの両方のモデルをまとめて一覧に出す。サインインは
「エージェント」>「プロバイダー」で行う（セットアップツアーにも残す）。「プロバイダー」には、アカウント自身のサインインと、
サインイン済みのサブスクリプション、追加した Databricks を並べ、それぞれに使い道（「モデル」「MCP」）のバッジを付ける（Databricks は両方）。サブスクリプションと
Databricks は「プロバイダーを追加」のモーダルで選んで追加する。設定のモーダルは窓全体に重ねる。追加はアプリ側のサインインで、接続は `provider_accounts` の行になり、Keychain が認証を持つ。アプリのアカウントは、Pi のサブスクリプションと、すべての接続の Gateway のモデルを一覧に出す。接続の provider ID はその workspace のホスト名（ドットを含む）である。接続の追加・削除では Pi のプロセスを止めない。`models.json` を書き直し、新しく起動するプロセスから使う。待機中のチャットは閉じて次の送信で開き直し、実行中のチャットはそのターンが終わってから閉じる。
表示名は Pi の名前に合わせる（`openai` は「OpenAI (ChatGPT subscription)」）。Dahlia account は自分の Server の provider だけを使う。

| 表示名 | Pi provider | 認証 |
| --- | --- | --- |
| OpenAI (ChatGPT subscription) | `openai`（Sign in with ChatGPT、agent 名 `Dahlia`） | Pi の OAuth。端末 ID は Local agent directory |
| Anthropic (Claude Pro/Max) | `anthropic` | Pi の OAuth |
| Databricks | 接続の workspace のホスト名（各モデルが Unity AI Gateway の経路を持つ: Claude は anthropic、GPT は codex、GLM・Kimi は mlflow、Gemini は gemini）。接続ごとに別の provider になり、複数を同時に使える | `provider_accounts` の接続の Desktop OAuth を bridge |
| Unity Gateway (ホスト名) | 接続がプロバイダーアカウントになる前に追加した workspace のホスト名（経路は Databricks と同じ。モデル名にホスト名の先頭の部分を付ける）。同じホストの接続を追加すると、その接続の bridge が優先される | Pi の OAuth（[Unity AI Gateway の MCP](#unity-ai-gateway-の-mcp)） |
| Dahlia account | `dahlia`（Server の `/api/v1/responses`） | Dahlia token を bridge |

Databricks のモデル一覧は Unity Catalog の `/api/2.1/unity-catalog/model-services?parent=schemas/system.ai` から作るので、
Gateway に追加されたモデルはアプリの更新なしで出る。一覧は extension の `/databricks-model-services` が Pi の中で取り（プロバイダーアカウントの
Gateway は `--provider <ホスト名>` で bridge した sign-in を使う）、token は Pi の外に出ない。各 Gateway が最後に答えた一覧は agent directory の
`gateway-models.json` に provider ごとに保存し、`models.json` はいつもこの保存した一覧とスイッチから作る（まだ答えていない Gateway は同梱の
`models` で代える）。スイッチの切り替えは network を使わず、保存した一覧から書く。一覧の取得は起動後に最初に
モデルを一覧するとき（と workspace へのサインイン後）に、サインイン済みの Gateway をまとめてバックグラウンドで1回だけ行い、モデル一覧は
それを待たない。取得で `models.json` の Gateway の項目が変わったときだけキャッシュを捨てて `DahliaPiModelsDidChange` を通知し、モデル選択が
読み直す。同じ Gateway の取得が同時に走るときは1つにまとめ、切替やサインインの後に始まった取得があればそれ以前の取得の結果は保存しない。
答えなかった Gateway と、テンプレートで使えるモデルを1つも返さなかった Gateway（system.ai を見られない sign-in、embedding だけの応答など）は
保存した一覧を保つ。
Pi は起動時にしか `models.json` を読まないので、開いているチャットの process が知らないモデルを選ぶと（`set_model` が失敗すると）、ターンを
始める前にそのスレッドを session file から開き直し、そのターンのアカウントと承認方式のまま選び直す。「モデル」ページは保存した一覧を表示し、まだない Gateway と再試行のときだけ取得を待つ。この API は単価・コンテキスト長・推論レベルを返さないため、同梱の
`PiExtension/databricks-models.json` のテンプレートで補う。`templates` は `system.ai.` を除いた名前に glob（`claude-*`、`gpt-*-luna`）で当て、
当たったものをファイル順に重ね、Gateway が返す画像入力、`models` のモデル個別の値の順に上書きする（各段はトップレベルの項目ごとに入れ替える）。
テンプレートの経路（`baseUrl` と、Gateway の `supported_api_types` に要る `gatewayApi`）がないモデルと tool を呼べないモデルは出さない。
並びは最初に当たったテンプレート、`models` の順、ID の降順。provider の `baseUrl` に workspace を記録する（各モデルは自分の経路で上書きする）。
Dahlia account はサインイン時に Server の URL だけを記録し（network 不要）、
モデル一覧の取得時に `/api/v1/models` を `models.json` に変換する。取得に失敗したら直前の一覧を保ち、空の一覧はキャッシュしない。
一覧は account ごとに1つの Pi 起動を同時の呼び出し元すべてで共有し、全員が取り消したときだけ止める。サインイン・サインアウト・
プロバイダーアカウントの追加・削除・Gateway モデルの有効・無効の切り替えはキャッシュを捨て、`DahliaPiModelsDidChange` を通知する。それ以前に始まった取得の結果は
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

「エージェント」>「モデル」ページは、各プロバイダーのモデル、要約生成、画像解析を同じページで設定する。AI による代理承認 (pi-auto-review) は「詳細設定」>「プラグイン」タブで設定する。要約生成・画像解析の設定リンクも「モデル」を開く。
Databricks の接続があるときは、Gateway ごとのモデルも「コネクタ」と同じくプロバイダーの行の下に折りたたんで並べ、モデルごとのスイッチでオン・オフする。
Local Account の ChatGPT・Claude も同じくプロバイダー行の下でモデルごとに表示を切り替える。
選択のないモデルは Claude Opus 5.5・Sonnet 5.5・Haiku 5.5、GPT 6.1 Sol・GPT 6.1 Terra・GPT 6 Luna だけをオンにし、保存した選択は再サインイン後も保つ。
サブスクリプションは Pi の認証・カタログを変更せず、Dahlia がチャット・要約・画像解析などへ返す一覧を絞る。
表示切替は Pi の一覧キャッシュを保ったまま `DahliaPiModelsDidChange` を通知する。
全モデルをオフにしてもサインイン状態と設定の全モデル一覧を保ち、再びオンにできる。Dahlia account 自身のモデルは対象外。
Pi の `models.json` には
モデルごとの有効・無効の項目がなく（`settings.json` の `enabledModels` は起動時の選択と切替の範囲だけで、`get_available_models` からは外さない）、
Gateway の有効・無効の設定は `models.json` を編集する。オンのモデルだけを `models.json` に書くので、Pi が知るのもチャット・要約・画像解析が選べるのもそれだけになる。
選択はサブスクリプションも Gateway も `provider/id` ごとに app defaults（`agentGatewayModels.local`）に記録し、選択のないモデルは既定に従う。Gateway の既定はオフで、Databricks の接続
（プロバイダーアカウント）の Gateway の、`models` で `onByDefault` を付けたモデル（Claude Haiku 5.5）だけがオン（その Gateway が Haiku を出さないときは先頭のモデル）。オンにしていたモデルを Gateway が出さなくなってその Gateway で
オンが1つもなくなるときは、この既定のモデルをオンとして扱い、設定の表示と `models.json` は同じ結果を使う。以前に追加した workspace は
すべてオフで始まる。要約は、保存した設定がなければ、プロバイダーアカウントとサブスクリプションのモデルを優先して先頭の利用可能モデルを使う。画像解析はモデルを保存せず、一覧にある Haiku を最優先で選び、Haiku をオフにすると次の候補（Luna、なければ画像を受け付ける最初のモデル）を使う。切り替えると保存した一覧から
`models.json` を書き直してキャッシュを捨て、`DahliaPiModelsDidChange` を通知する。チャットにはモデルが要るので、Databricks の接続の Gateway では最後の1つをオフにしても既定のモデルをオンとして扱う（以前に追加した workspace は外せるので
対象にしない）。
すべてオフにした Gateway は、モデルのない provider として `models.json` に残す（workspace と sign-in のため）。オフにしたモデルが保存されていた要約は、フォールバックが設定されていればそのモデルを試し、未設定なら先頭の利用可能モデルを使う。チャットは先頭の利用可能モデルを使う。画像解析は保存したモデルが見つからない場合も設定したフォールバックを試し、未設定なら失敗する。

サインインは extension の `/dahlia-login` が Pi の login を呼ぶ。Pi の extension API に login がないため
非公開の `modelRegistry.runtime` を使い、Pi 更新時に回帰確認する。
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
以外は生成失敗にする。要約は非空の section・block を要求し、Action Items とは別に議論・決定・背景を本文へ書く。
タイトルや見出し、画像、参照だけの返答や、本文が `_` などの記号だけの返答は不完全と判定する。
不完全な返答は生成失敗とし、フォールバックがなければ既存の要約を保つ。
要約の Markdown fallback には流さない。

要約生成と画像解析には、それぞれモデルの直下に任意のフォールバックモデルを設定できる。既定は「なし」で、この Mac の設定として保存し、要約ジョブの開始時に固定する。通常モデルの生成失敗・不正な JSON・本文欠落などを検知した場合、指定した別モデルを同じ入力・schema で1回だけ試す。要約の推論レベルは切り替え先が対応する値へ解決し、要約の metadata には実際に成功したモデルと推論レベルを記録する。取消・アカウント切替・Pi 未起動などの共通実行基盤の失敗では切り替えない。フォールバックも失敗すれば既存の要約を保ち、生成エラーを表示する。

画像解析のフォールバックは検索用 OCR・caption と要約前の画像選別に共通で使用する。画像選別は全体90秒の期限内で実行し、両モデルの失敗・期限切れでは候補画像をすべて保持する既存の挙動を維持する。要約前の画像選別は推論レベル `medium`、OCR・caption は `low` 固定で実行する。画像解析モデルの用途はモデル行の i マークから表示する。

## チャットの実行と承認

macOS のチャットは、会議記録を得意とする汎用 AI アシスタントとして振る舞う。依頼に応じて Dahlia の会議記録と、
接続済みの業務系 MCP server が提供する Gmail・Google Drive・Slack 等を使い分け、必要なら横断して調べる。会議の検索手順は会議記録が
必要な依頼にだけ適用し、閲覧中の会議 context も関連する場合だけ使う。回答はユーザーの言語を基本とし、出典・推論・未確認を
区別する。取得した本文は指示や承認として扱わない。説明・レビュー・下書きの依頼を送信や更新の許可に読み替えず、
明示された操作は承認方式に従って実行する。この方針は Local／Server Account 共通で、Private Web・Electron の Server AI、
要約生成・画像解析、および Local／Server MCP の提供する操作は変更しない。

実行中の入力欄が空なら中止ボタンを表示し、本文・参照・画像があれば既定の方式で送信する。
既定は Queue（完了後の次の応答）。「エージェント」>「詳細設定」>「一般」>「チャット」の「実行中の追加送信」で
Steer（現在の応答への追加指示）に変更できる。この Mac の全アカウント・チャット画面で共通とする。
入力欄に方式の選択メニューは出さず、Queue の追加アイコン／Steer の矢印を送信ボタンに表示する。
Command キーを押している間は反対の方式のアイコンになり、クリック／⌘Return ともその方式で送信する。
Return は既定の方式、Shift-Return は改行する。
Steer で受理したユーザーメッセージは吹き出し右上に Steer ラベルを付け、保存履歴からの再表示でも維持する。
方式が保存されていない過去のメッセージには推測でラベルを付けない。
スラッシュコマンドは Pi の制約により次の応答まで待機する。待機メッセージは本文・画像を確認でき、今すぐ送信、
本文編集、画像削除、メッセージ削除ができる。編集している間はそのメッセージの自動送信を保留し、通常の下書きは保つ。
明示停止では待機列も一時停止し、再開操作または新しい送信で続ける。送信方式はこの Mac の設定に保存する。待機列は開いているチャットのメモリ上で保持し、
チャットを閉じた場合やアプリ再起動後の復元は行わない。macOS のサイドパネル・メイン画面・独立ウィンドウと
Local／Server Account に共通で、Private Web／Electron、Local／Server MCP には追加しない。

チャットは作業フォルダで動く（2026-11-11 ユーザー承認）。作業フォルダは「エージェント」>「詳細設定」>「セキュリティ」で設定し（`piWorkingDirectory.local`）、
既定は `~/Dahlia`（development profile は `~/Dahlia-Development`）。チャットが自由に書けるので、sandbox の外で実行されるもの（shell の設定、ホームの下に入れた tool と Pi、app の設定）を含むフォルダは指定できない:
ホームフォルダ自身、それを含むフォルダ、`~/Library` とその中、`~/.dahlia` とその中、相対 path、Pi を探して起動するときの PATH の folder を含むフォルダ（`pi` を置き換えたり、`node` より先に見つかるコマンドを置いたりできる）は、チャットの起動時に拒否する。`~/Documents` は macOS がアクセス許可を求め、iCloud に同期されうるので使わない。フォルダはなければ作る。
Pi は thread を session file の header の `cwd` で動かすので、Dahlia は thread を開き直す前に header の `cwd` を今の作業フォルダに書き換える。設定の変更は次に起動する chat process から効く。
以前の `Application Support/<profile>/CodexChatWorkspace/<Workspace ID>` は使わず、削除もしない。

Pi に渡す tool は `read`・`ls`・`write`・`edit`・`bash`・`mcp__dahlia__*` と、アカウントに登録した MCP server の tool（2026-11-11 ユーザー承認）。`grep`・`find` は渡さない。
「セキュリティ」で追加のファイルアクセスを設定できる（2026-11-12 決定）。初期値は追加なし。選択時は読み取りのみで、読み書きへの変更と許可の削除ができる。保存先はこの Mac のアカウント別設定で、Server に同期せず、AI/MCP から許可を編集する入口は設けない。macOS チャットだけの機能であり、Private Web・Electron・Server の処理権限を変更しない。

追加の許可でも Pi の実行コード・extension・skill・Pi 用一時フォルダは書き換えられず、Dahlia の認証情報・録音などの保護対象にも到達できない。ホーム全体や Library、PATH のコマンドを含む／その配下の場所への書き込みは拒否する。標準の zsh・bash・csh 起動ファイルと fish 設定、および起動環境の HOME・ZDOTDIR・XDG_CONFIG_HOME・BASH_ENV・ENV で指定した起動ファイルは、シンボリックリンクの参照先も含めて書き込みから保護する。それらを含む追加の読み書き許可は保存・起動時に、作業フォルダは起動時に拒否する。Seatbelt でも許可ルールの後に書き込みを拒否する。読み取りのみの許可は使える。BASH_ENV・ENV は直接のファイル path（絶対、相対、`~/`）に限定し、シェル式や `~ユーザー名` を含む値が設定されている場合は chat 起動を拒否する。式を評価して sandbox 外で起動先を推測することはしない。設定から選んだ path は実体に解決し、起動時にも検証する。許可は既存の範囲に加算するもので、読み取りのみの追加や削除によって作業フォルダの書き込みを禁止することはできない。ファイル単位の許可は隣接ファイルの作成や置き換え用の一時ファイルを許可しないため、それを必要とするツールには親フォルダの許可が必要になる。

追加・変更・削除は次のメッセージから反映する。Seatbelt は process 起動時に固定されるので、権限設定が変わった既存の idle thread は次の turn 前に開き直す。実行中の turn と子コマンドの権限は変更しない。すぐに停止する必要があれば応答をキャンセルする。ネットワークの許可は変えず、追加した読み取り対象も外部へ送信可能である。

5つの tool の範囲は上の Seatbelt の表のとおりで、範囲内は確認なしで動く。system prompt には SQLite と画像の保存先の path を含め、`sqlite3 -readonly` で参照できる。
実行中のターンでは、直近の tool 名と実行中・完了・失敗・アクセス不可の状態を入力欄の上に表示し、終了結果の受信後はモデルの応答待ちと明示する。引数と出力本文はこの状態表示に含めず、回答本文の受信またはターン終了時に消す。アクセス制限を受けた同じ path の再試行や sandbox の回避をせず、制約を説明して参照可能な情報から続けるよう system prompt で指示する。

| 選択 | read / ls / write / edit / bash | 登録済み MCP の変更操作 |
| --- | --- | --- |
| 常に確認する（Supervised） | Seatbelt の範囲内は確認なし | 毎回ユーザーに確認 |
| AIにより確認する（Auto review） | 同上 | `pi-auto-review` が審査し、許可できない操作・審査失敗はユーザーに確認。critical 判定は実行を拒否 |
| すべての承認をスキップ（Full access） | 同上 | 確認なし |

MCP の承認は上の3段階とする（2026-11-12 決定）。Full access でも Seatbelt を解除せず、ファイルやコマンドのアクセス範囲は広がらない。
MCP の tool は Dahlia がその chat に登録した server（Dahlia MCP とアカウントに登録した server。`DAHLIA_PI_MCP_SERVERS`）だけを通し、
それ以外はどの選択でも拒否する。Dahlia MCP の `get`・`query`・`list`・`search` と、gateway MCP の `readOnlyHint` が true の tool は確認・審査なし。
MCP の読み取り結果も untrusted data として扱う。

`pi-auto-review` は審査済みコミットの `index.ts` をアプリに同梱する（`PiExtension/pi-auto-review`、固定コミットは同じフォルダーの `UPSTREAM.md`。2026-11-27 ユーザー承認）。
Pi は `--no-extensions` で起動するためその既定 extension は読み込まれず、Dahlia の MCP gate が同梱ファイル（`DAHLIA_PI_AUTO_REVIEW`）から
公開された `review` 関数だけを import し、審査モデル・推論強度・トリアージを呼び出しごとの設定で渡す。同梱ファイルはアプリの bundle にあり、チャットから書き換えられない。
import できない、または設定を受け取らない API の場合は審査せず、手動確認へ戻す。チャットの「AIにより確認する」はどのアカウントでもいつも選べる。
審査モデルは「エージェント」>「詳細設定」>「プラグイン」> pi-auto-review のカードの設定で指定し、`autoReviewModel.local` に保存する。
空の選択（既定）は審査時点のチャットモデルを使う。変更は起動済みのチャットでも次の審査から効き、`PI_AUTO_REVIEW_MODEL` や Pi 側の `autoReview` 設定より優先する。
reasoning effort は審査モデルの価格情報から自動設定する。Pi の100万トークン当たりの入力価格が2 USD以上、または出力価格が10 USD以上なら low、それ未満なら high。
価格情報がない・ゼロの場合はモデル名に関係なく high にする。「チャットと同じモデル」でも審査の推論強度はこの規則で選ぶ。
審査は追加のモデル呼び出しになり、その provider に履歴と予定操作を渡す。
同じ設定画面のトリアージは既定で無効。`autoReviewTriage.local` に保存し、次の審査から反映する。
接続済み Unity AI Gateway のモデルサービス一覧から System One API を提供する `system.ai.openjev-qwen35-4b` を取得できた場合だけ有効化できる。
トグルのオン操作時に接続先へ確認し、成功した場合だけオンを保存する。確認に失敗しても再びオン操作で再確認でき、古い取得状態でトグルを操作不能にはしない。
確認済みのモデル・接続先情報は保持して審査時に再利用し、設定画面の表示や審査ごとには再取得しない。
OpenJev にユーザーのメッセージと予定する MCP 操作を渡し、upstream の OpenJev 既定閾値0.85で日常的と判定した操作は審査モデルを省略する。Pi 側の `autoReview.triage` は使わない。それ以外や取得・判定の失敗は通常の審査へ戻す。
審査の critical 判定・ユーザーの拒否などで操作をブロックした後は、その実行の残りでトリアージを使わず、次の MCP 変更操作を審査モデルへ渡す。次の `agent_start` でトリアージの利用を再開する。
設定の i マークで送信範囲と挙動を説明し、トリアージの無効化はモデル取得に失敗していても行える。
会議 context と live transcript は審査履歴でも user の承認として扱わない。審査には予定操作の全文・審査指示・履歴を渡す。
審査できる大きさは upstream の `review` が判定する。予定操作が128,000文字を超えるか、審査指示・履歴と出力用の16,000トークンを含めて審査モデルの context window に収まらない場合は
審査せず、全文を表示する手動確認へ回す（context window はUTF-8の2バイトを1トークンとして見積もる）。完全な要約の更新も128,000文字を超えると手動確認になる。
Jev は upstream の32,000文字上限を維持し、それを超える予定操作は通常の審査モデルへ渡す。
審査の期限・再試行・取消は upstream に従う。否認・失敗の理由を承認画面で表示する。

承認方式は Dahlia が保持し、extension は MCP の変更操作ごとに bridge で問い合わせる（turn 中の変更も次の呼び出しから効く。不明なら「常に確認する」）。
Pi の session file に承認方式を保存しない。全アカウントで、新しい thread も開き直した thread も「AIにより確認する（Auto review）」を初期選択する。開いているチャットで明示的に選んだ承認方式は保持する。
承認対象の UTF-8 合計は command／file change／MCP 共通で、既存の process transport の受信保護上限と同じ4MiBまで保持する。
MCP は server・tool・整形済み引数全文・reason を含めて検査する。4MiBを超えて表示を切り詰めた呼び出しは、承認方式によらず許可しない。
AI 審査の入力容量とアプリの受信保護上限は分けて扱う（参考: [公開実装の入力予算](https://github.com/openai/codex/blob/ca21fe65d18a9b6326759fb4263c65dfbb645aa5/codex-rs/guardian-context/src/budget.rs)）。4MiB は Dahlia の保護上限である。
取消・停止は未応答の承認を cancel してから abort する。
Codex の web search、`request_user_input` は Pi にないため提供しない。

新規チャットの追加メニューに「コネクタ」を表示し、選択時は元のメニューを残して右側に一覧と設定への入口を開く。
両パネルは下端を揃え、一覧はアイコンとコネクタ名だけを表示する。内部 ID は表示しない。既存チャットにはこの項目を表示しない。
狭い画面では両パネルの幅を調整し、外側クリックまたは Esc で閉じる。

### Unity AI Gateway の MCP

採否は[エージェントによる MCP 経由の外部サービス操作](agent-mcp-operations.md)に従う。
設定のサイドバーは「エージェント」グループに「プロバイダー」「モデル」「コネクタ」「スキル」「メモリー」「詳細設定」をこの順で並べる。「モデル」と「コネクタ」は独立したページで、「詳細設定」（旧「Dahlia AI」）は「一般」「定期実行」「プラグイン」「セキュリティ」のタブを持つ（2026-11-27 ユーザー依頼）。
アプリのアカウントに、「エージェント」>「プロバイダー」で Databricks の workspace（sign-in）を追加し、「エージェント」>「コネクタ」で
その workspace の MCP server を登録する（2026-11-09 ユーザー承認）。「プロバイダー」には、アカウント自身のモデルのサインインも並べる。モデルの
workspace と MCP の workspace が異なることが多いため、MCP 用の workspace はモデルとは別にサインインできる。
Databricks の接続（プロバイダーアカウント）の workspace の MCP も選べ、その server は `auth.provider` にその接続の bridged provider（ホスト名）を指定して
接続の token を使う。一覧も `/databricks-mcp-services <URL> --provider <ホスト名>` でその token で取り、ここではサインインもサインアウトも
しない。この workspace は最初の server と一緒に保存し、最後の server を外すと消す。登録は app defaults（`agentMCPs.local`）に保存する。
Unity Gateway の MCP service は登録の操作なしで一覧からトグルにより有効にする（2026-11-09 ユーザー承認）。「コネクタ」ページは、アカウント自身の workspace と「プロバイダー」で
追加した Databricks を折りたたみ可能な見出しとして並べ、その下に MCP service を2列のカードで表示する。一覧は中央の設定カラムに収め、カードには名前と API の `comment` を表示し、検索は説明も対象にする。各 MCP service のカード右上にトグルを置き、有効な MCP だけ、その左に小型の円形の認証表示と処理中のキャンセルを表示する。プロバイダーのサインインは「プロバイダー」で行う。オンにすると server を登録し、オフにすると外す。
各 provider のすべてのサービスカードの後に「MCP サーバーを追加」カードを置く。`main.default.notion` のような完全名を入力すると有効なカードとして追加し、無効化後も一覧に残す。追加用カードは常に最後に表示する。
server 名は service 名の最後の部分（`system.ai.github` なら `github`）である。オンにする操作（トグルと「MCP サーバーを追加」）でその名前を別の server がすでに使っていれば、アプリ内モーダルで「置き換える」か「別名で登録」かを選ばせる。置き換えると古い server をオフにし、新しい server がその名前を引き継ぐ。直接設定の server を使うスケジュールは、置き換え後にツールの許可を見直す。直接設定の server は設定を失わないよう、削除せずオフにして番号付きの名前（`github_2`）に変える。別名は `github_2` を初期値に入力でき、カードの名前の横に示す。キャンセル・Escape・背景クリックでは何も変えない。
接続を持つ Databricks の見出しには Omnigent のカードも置く。Omnigent はアカウントにつき1つの接続でしかオンにできず、別名で登録できない。別の接続でオンにすると、置き換えるかだけを尋ね、置き換えると前の接続ではオフになる。

並べる MCP service は、その workspace の Unity AI Gateway が sign-in に見せるもの（`system.ai` の下で状態が ACTIVE のもの。
`GET /api/2.1/unity-catalog/mcp-services`）と、登録済みの service である。最後に取った一覧を設定に残して展開したときに先に示し、展開する
たびに取り直す。取り直しに失敗しても前の一覧を残し、失敗を示す。一覧は token を持つ Pi が control process の `/databricks-mcp-services <workspace URL>`
で取り、Dahlia には名前と `comment` を返す。説明も最後の一覧とともに保存し、取得失敗時は保持する。`system.ai` 以外の schema は自動列挙せず、完全名で登録した有効な service だけを個別の GET API で取得する。server 名は tool
名の接頭辞（`mcp__<name>__`）になるので、英小文字・数字・`_` の40文字までとし、`_` を連続させず（`mail` と `mail__work` の tool 名が区別できなくなるため。登録済みの名前はそのまま残す）、アカウントの中で重複させず、`dahlia` を使わない。既定は
service 名の最後の部分（`system.ai.github` なら `github`）で、重複するときは番号を付ける。名前は自動で割り当て、設定からの変更は提供しない。同じアカウントで複数の workspace を登録できる。

### 直接設定の MCP

「コネクタ」ページの provider の見出しより上に「直接設定」の見出しを置き、stdio のコマンドまたは streamable HTTP の URL で設定した server を同じカードで並べる（2026-11-27 ユーザー依頼）。
最後の「MCP サーバーを追加」カードはどちらの方式も共通で、アプリ内モーダルの切り替えで stdio（コマンド・引数・環境変数）か HTTP（URL・ヘッダー）を入力する。サーバー名・接続方式・コマンド・URL はラベルで示す。引数は1つずつ独立した欄に入力し、環境変数とヘッダーは名前と値の欄を分けた行で、いずれも＋ボタンで行を足し、－ボタンで消す。
フォームと JSON 入力を切り替えられる。JSON は64 KiB 以下の接続設定1件、名前付き設定1件、または1件の `mcpServers` を受け付け、`type`・`command`・`args`・`env`・`url`・`headers` に対応する。名前付き設定はその名前で登録し、既存サーバーの名前は変更しない。引数内の空白・改行・空文字を保持する。 JSON からフォームへ戻すときは、その JSON の接続方式の欄だけ更新し、もう一方の下書きを保持する。生成した JSON が64 KiBを超える場合はフォームに留め、下書きの編集・保存を続けられるようにする。HTTP URL の port は0〜65535とする。登録時に Pi が拒否した接続は通知し、他の接続と sandbox・承認処理の初期化を継続する。
名前は Unity Gateway の server と同じ規則・同じ名前空間で、追加時だけ入力する。カードには名前とコマンドまたは URL を表示し、鉛筆ボタンで同じモーダルを開いて設定の変更・削除を行う。接続内容を変えると既存の Source の許可は無効になり、新しい Source の作成が必要になる。
トグルは設定を残したまま Pi への接続設定の受け渡しとイベントソースの許可を止める。登録は Unity Gateway の server と同じ `agentMCPs.local` に `providerID` なしで保存し、`env`・`headers` は入力どおり平文で残す。
秘密の値は「環境変数」に置き、Pi が `${VAR}` で解決する。Pi に渡す設定は `command`・`args`・`env`、または `url`・`headers` と `exposure: "direct"` を持ち、`auth.provider` は持たない。
stdio の server は Dahlia MCP と同じく Pi の子として Seatbelt の外で実行される。tool の承認は他の MCP server と同じ。OAuth が必要な HTTP server のサインイン（Pi の `/mcp login`）は提供しない。

sign-in は workspace ごとに1つで、その workspace の server すべてが共有する。どの server を使っても同じ refresh token が更新される。
Databricks provider（`PiExtension/databricks-provider.ts`）が sign-in を provider として登録する。provider 自体はモデルを持たず、
モデルは Dahlia が `models.json` に書く（Gateway の 3 つの API を持つ）。provider の ID は workspace の
host（port があれば `:<port>` を付ける）で、同じ workspace をもう一度追加するとサインインし直し、provider は1つのまま使う。アカウント自身の workspace は追加させない。チャットはドットで Pi 自身の provider と区別するので、ホスト名にドットのない URL も追加させない。設定ではどの Databricks の provider も「Unity Gateway (ホスト名)」と1行で示し、表示名は持たない（2026-11-09 ユーザー承認）。
この provider の `auth.oauth` が workspace の `/oidc/v1/authorize`・`/oidc/v1/token` に対して PKCE の認可コードフローと refresh を行い、
Pi がその credential を agent directory の `auth.json` に保存し、ロックの中で refresh する。credential には token と一緒に workspace の
origin と client を保存するので、どの process も provider の ID だけで refresh できる。`dahlia.ts` がどの process でも
`registerDatabricksProviders` を呼び、起動時に `DAHLIA_PI_MCP_CONFIG` の `auth.provider` と `models.json` の provider のうちドットを含む ID
（Pi 自身の provider の ID にはない）を provider として登録する。Dahlia は provider の一覧を環境変数で渡さない。`/databricks-login`・
`/databricks-mcp-services`・`/databricks-model-services` は `dahlia.ts` の control 用の分岐が import して登録する。
client の既定は Databricks CLI の公開 client `databricks-cli`（redirect は `http://localhost:<8020〜8040>`）で、Pi が自身の
Client ID Metadata Document を公開したらそれに差し替える（2026-11-09 ユーザー承認）。scope は `ai-gateway unity-catalog offline_access`（MCP の呼び出しに `ai-gateway`、MCP service の一覧が Unity Catalog の API なので
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
サービスの接続（GitHub など、利用者ごとの OAuth）へのサインインは、「コネクタ」ページの各 service のカード右上のサインインアイコンで始める。
Databricks SQL・Sandbox・Genie One・Web Search（`system.ai.dbsql`・`sandbox`・`genie_one_mcp`・`web_search`）は workspace のサインインを使うので、追加認証の表示と状態確認の対象にしない。接続先の認証状態は、有効化している追加認証対象の MCP だけを対象に、Beta の `GET /api/2.1/unity-catalog/mcp-services/<service>/user-credentials` で一覧取得時・有効化時・サインイン完了後に確認する（`--enabled` で対象の service 名だけを Pi に渡す）。`provisioning_info.state` が `ACTIVE` のときだけクリック操作のない円形の緑のチェックバッジを表示し、それ以外の状態または `NOT_FOUND` はサインインが必要として示す。API 非対応・権限不足・通信失敗は未確認として表示する。未認証・未確認のときは円形のサインインボタンを表示し、無効な MCP には認証表示を出さない。無効化したら進行中のサインインも取り消す。状態は Pi から列挙結果に添え、token や有効期限は渡さず、アプリ終了後に再利用する設定にも保存しない。トグルはその MCP の利用設定を表し、認証状態とは独立する。
control process の `/databricks-connection-login <workspace URL> <service>` が、その service の URL を `resource`（RFC 8707）
に付けた認可要求をブラウザで開き、workspace が接続のサインインを済ませてから返す認可コードは token に交換しない（workspace の sign-in は
そのまま）。終わるとそのアカウントのチャットの process を閉じ、次の turn で接続し直す。MCP が返すリンクからのサインインもそのまま使える。

OpenAI Responses の function tool は、`strict` の指定がない場合に `false` を明示し、MCP schema の任意引数を任意のまま渡す。明示された空文字・`null`・`false` は省略に置き換えず、承認と実行に同じ値を渡す。

チャットの process を起動するたびに、Dahlia は許可する MCP の接続設定をその process の環境変数 `DAHLIA_PI_MCP_CONFIG` に固定し、extension が Pi の `registerMcpServer` で登録する。
Gateway は `<workspace>/ai-gateway/mcp-services/<service>` の `url`・`exposure: "direct"`・`auth: { provider: "<sign-in の provider>" }`、直接設定は[その設定](#直接設定の-mcp)を渡す。
共有の `mcp.json`（0600）は空に保ち、別の thread の起動が接続範囲を広げない。`--no-approve` で作業フォルダの Pi 設定も読み込まない。
通常のチャットには有効な接続、エージェントの会話には Dahlia MCP だけ、取り込みには Source の接続だけ、定期実行には承認済みの接続だけを渡す。
`--tools`・`DAHLIA_PI_MCP_SERVERS` も同じ時点の設定から作る。接続設定の変更はその後に起動する process から効き、開いている thread は閉じるまで前の設定のまま動く（遅れはユーザーが許容。2026-11-07）。
直接設定を使う定期実行の許可は接続 ID にも結び付け、承認中の変更、実行中の変更、削除と同名での再登録を許可の引き継ぎに使えない。接続変更後はチャットから予定を更新して再承認する。

履歴の正本は app の GRDB の `chat_threads` と追記専用 `chat_items`。Dahlia では永続的な会話を Thread、
その時系列ログを Item と呼ぶ。session は Pi／Databricks のアダプタ内と録音の用語に留める。台帳は常に GRDB に置き、
将来の Databricks managed memory session store への切り替えは `ChatItemStore` の裏のアイテムログだけを対象とする。
Thread はアプリのアカウント（`accountID` は `local`）に属し、Workspace とは直接関連付けない。Project は議事録と同じ `projects.id` を任意で参照する。
チャット入力欄の枠のすぐ上に Project だけを表示する。新規 Thread ではすべての Workspace の Project または「プロジェクトなし」を選べる。
Project のパスが重複する場合は選択肢と保存済みの表示に Workspace 名を補い、Workspace 名も同じ場合はその識別子を添えて区別する。
未選択なら最初の入力の Project／Meeting context を初期値に使い、Thread 作成時に「プロジェクトなし」も含めて関連を確定する。
最初の送信以降は表示のみとし、初回実行前の失敗・再試行でも関連を変更しない。
Project がない Thread は Workspace に属さず、Workspace 切替では履歴・実行中の会話を維持する。
Project から実行先 Workspace を解決しない。チャットの Dahlia MCP はすべての Workspace を読み、Project はその範囲を狭めない。
Project を削除しても Thread は保持して紐づけだけを外す。
親 Thread は作成時だけ指定でき、子を持つ。親を削除すると子とその Item も削除する。
子の起動・結果配送は[スレッド管理の設計判断](chat-thread-orchestration.md)を参照。

ユーザー入力は送信前、アシスタント応答は `message_end`、ツール結果は実行完了で保存し、途中の文字デルタは保存しない。
入力の引き受けは実行成功を意味せず、送信エラーも Thread の失敗状態に残す。ツール名・引数・結果・成功／失敗／アクセス不可を保存し、
引数と結果は各64 KiBを超えた場合に明示的な切り詰め印と preview を残す。ツール詳細の履歴表示は対象外。
応答中に送った追加指示は Pi が配信した時点で保存し、割り込んだ応答の後に並べる。配信されずにターンが終わった追加指示は、プロセス切断や終了による場合も含めて最後に保存する。
起動時に実行中・承認待ちだった Thread は中断扱いにする。サインアウトでは残し、アカウントを削除したときだけその履歴を削除する。
Pi の session file は実行アカウントの `sessions/shared` に作る。既存の `sessions/<Workspace ID>` のファイルも移動・削除せず実行再開に使う。
既存の Pi ファイルから履歴を自動取り込みせず、表示履歴とタイトルは GRDB だけから取得する。
Pi の応答を保存済みの Thread に Pi ファイルがなければ閲覧だけ可能とし、
文脈なしで実行を再開しない。Pi は最初の応答でファイルを書くので、応答のない Thread は Pi を新規に開始する。Codex の rollout は取り込まない。
スラッシュ候補で `/clear` を選ぶ（または入力して送る）と Pi には送らず、次に受け付けたメッセージから同じ Thread ID の新しい Pi session を始める。待機中は入力欄の上に表示し、そこから取り消せる。
切り替え指定はそのメッセージに属し、先にキューへ入れた入力には適用しない。キュー内の編集・開始前の失敗後の再試行でも保持し、該当入力を削除すれば取り消せる。キュー内では該当入力に新しいセッションの表示を付ける。先の入力が失敗した場合は、エラー表示の「スキップして続行」でその入力を再送せず、切り替え指定と後続入力を残して待機列を順に進められる。切り替え指定を持つ入力自体が保存前に失敗した場合は、新しい入力も待機列へ入れ、スキップ時にその先頭へ指定を引き継ぐ。保存済みの指定は引き継がない。未確定の切り替えが失敗した状態と理由はモデル一覧の再読込では消さず、再試行またはスキップを選ぶまで自動送信・待機列の再開・「今すぐ送信」を止める。
「今すぐ送信」でも切り替えの入力と前後の入力は互いを追い越さない。該当入力とそれより後の入力は切り替え前のセッションへの追加指示（`steer`）に流さず、現在の turn の後に送る。そのメッセージの Item に `freshSession` を保存し、表示履歴は残したまま
メッセージの上に「新しいセッション」の区切りを表示する。旧 session file は削除せず拡張子 `.cleared` を付けて Pi と Dahlia の探索から外す。
上の閲覧専用の判定は最後の `/clear` 以降の応答だけで行う。開始中にアプリが終了した場合も、`/clear` のメッセージが未保存なら旧セッションを復旧し、保存済みなら新しい境界を維持する。保存後に Pi が入力を拒否した場合も、開始中に停止して待機列へ戻した場合も、再試行で切り替えを重ねない。別の実行がすでに動いていて切り替えを拒否した場合、その実行を中断しない。

履歴を開くと直近40件のメッセージだけを読み込み、過去分はユーザー操作で40件ずつ追加取得する。
ツールログはこの表示用ページングの件数に含めない。履歴一覧とメッセージ取得は複合キーの範囲探索でページングする。

Mac の検索は Thread のタイトルとユーザー／アシスタントの表示本文を共通の全文検索索引に含める。
タイトルと各メッセージを別々の検索文書にし、追加時は新しいメッセージだけを索引化する。ツールログの追記では索引を更新しない。
検索結果は Thread ごとにまとめ、複数語の AND 条件はタイトルと複数メッセージをまたいで満たせる。
会議 context、live transcript の隠しブロック、推論文、ツール引数・結果、画像データは索引に含めない。
アカウント・Project（子Projectを含む）・更新日時の期間で絞り込み、タグ付き検索ではチャットを返さない。
辞書を変更して全文検索を再構築するとチャットも再構築する。チャットは会議と別の全文検索表（`search_chat_documents`／`search_chat_documents_fts`）に索引する。メッセージごとに索引するので、同じ表に入れると会議検索の関連度順位（表全体の統計に依存する）が変わり、ページ送りがずれるため。チャットの索引 job は会議検索のカーソルを無効にする索引リビジョンも進めない。Mac のチャットはローカル保存・ローカル検索であり、
Private Web／Electron の Mastra チャットや Server MCP の検索対象にはならない。
チャットは DB デバッグ読み取りの既存の全アカウント例外に含まれ、通常の検索・履歴 UI のアカウント境界とは異なる。
Thread／Item とその検索索引は Workspace バックアップと Server 同期には含めない。チャットのバックアップツールは対象の `workspace_id` を必須引数とし、実行アカウントへの所属を検証する。

チャット入力の先頭で `/` を入力すると、Pi の `get_commands` が返す拡張コマンド・プロンプトテンプレート・スキルを名前と説明で絞り込む。候補は最大50件、幅は最大320ptとし、入力欄の上を優先して表示する。上に収まらないときは画面内に収まる側へ配置し、縦はスクロール可能とする。クリックまたは ↑↓ と Tab／Enter で補完し、Esc・外側クリック・引数の入力で閉じる。補完だけでは送信しない。応答の生成中に送信したスラッシュコマンドは追加指示用の `steer` に流さず、現在の turn の終了処理後に `prompt` で実行する。待機中のコマンドは入力欄の上に表示し、キャンセルできる。後続の入力もキューの順序を保つ。`/mcp` などが RPC の通知で返す結果はチャット内に通知の種類に応じたアイコン付きのオレンジの1行見出しと、展開・折りたたみ可能な等幅テキストの詳細として表示する。見出しは改行を空白に置き換え、利用できる横幅まで表示する。詳細は初期状態で折りたたみ、展開すると改行と全文を表示する。通知は表示中の会話に残すが、Pi の履歴に保存されないため会話を開き直したときには復元しない。agent run を起こさないコマンドも結果通知の後で完了する。TUI 専用の `/settings` などは候補に含めない。Pi の組み込みコマンドのうち `/compact` だけは候補に加え（応答がまだない会話では候補に出さない）、`prompt` ではなく RPC の `compact` で実行する。`/compact` の後ろの文字列は要約の指示として渡す。画像の添付には対応せず、画像付きの入力は下書きと添付を残して送信前に拒否する。待機中の入力も画像を外すまで実行せず、編集・キャンセルできる。圧縮中は会話内に「コンテキストを圧縮しています」の区切り線を表示し、成功すると圧縮前のトークン数と Pi が推定した圧縮後のトークン数を示す区切り線に置き換える。この区切り線は Item として保存し、会話を開き直しても復元する。前回の圧縮以降に要約できる会話がないと Pi が返したときは、失敗ではなく「圧縮できる新しい会話はありません」の通知を出して turn を完了する。それ以外の失敗はエラー、停止は中断として turn を終える。Pi がコンテキスト上限に近づいて自動で圧縮したときも同じ区切り線を表示し、turn は続ける。手動圧縮中の会話を開き直しても後続入力は Dahlia の待機列に残し、圧縮後に新しい turn として送信する。通常の応答中の自動圧縮では追加指示を送れる。メッセージのある Thread では Dahlia の `/clear` を先頭に出し、Pi の同名コマンドは隠す。コマンドは Pi が先頭で解釈できるよう閲覧中の会議・Project の自動 context を付けず、明示的に添付した会議参照はコマンドの後ろに付ける。この入力補完は macOS の Local／Server Account 共通で、Private Web・Electron の Server AI や MCP の操作は対象外。

## 検証

fake transport で RPC の順序・失敗・取消を、`test-pi-extension.py` で実 Pi とローカル gateway の
token bridge（Anthropic・Gemini・OpenAI の各 API と redirect 先に付かないこと）・strict schema・読み書きの範囲・MCP の承認と、ローカルの
OIDC での MCP の sign-in（databricks-cli と、Redirect URL を登録した client）・token・refresh（`auth.provider` のない MCP に付かないこと）を確認する。Pi 更新時は RPC event、extension API、
login の非公開 API、`text.format` の payload 形を回帰確認する。`test-pi-extension.py` は5つの tool を `pi.sb` の中で動かし、sign-in と秘密の環境変数が読めないこと、symlink で外に書けないことも確かめる。
sandbox の境界（書き込み・ホームと agent directory と一時フォルダの読み取り・symlink・Unix socket）は `PiSandboxTests` が実際の `sandbox-exec` で確かめる。

## 却下した案

- 無制限の stdout buffer: メモリ無制限化を持ち込むため。
- 画像入力の一時ファイル化: 別の所有・cleanup 契約を持ち込むため。
- 固定の4 MiB 行上限: 画像入力の正常な echo を拒否するため（上限は送信済みの入力に連動させる）。
- 行数による先読みの拡大: OS の callback 分割による誤った overflow を防げないため。

## 未適合・未検証

- 未確定: 要約・画像解析の process が承認の要求にどう応じるか。Codex では read-only / never で動かしていた。
- 未確定: 「MCP server を登録する」（workspace の sign-in 節）と、Unity Gateway の MCP service をトグルで登録する記述（MCP 節）の対応。
- 未確定: 停止後に受信済みの本文を残すか。
- 未実装: 画像対応が不明なモデルでもテキストで続ける規則。現在の実装は不明を対応ありとして扱う。
- 未確認: subscription の利用条件（OpenAI の Sign in with ChatGPT の登録区分、Anthropic の第三者利用）。ライセンスとは別に確認が残る。
- 未実装: Project 画面の一覧。
