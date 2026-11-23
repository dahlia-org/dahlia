# 単一アカウントへの移行とプロバイダーアカウント

対象: macOS アプリ（`apps/macos`）。Electron alpha・Desktop v2・Private Web・Server は対象外。
状態: 段階 1 と、段階 2 のうち `provider_accounts` への改名を実装した（未コミット）。判断 1・2 はユーザーの指示どおりで、判断 3 は段階 3 で必要になる。
前提: [常時実行エージェント](https://github.com/dahlia-org/dahlia/pull/840)（PR #840、未リリース）は、この改修の後に合わせる。
リリース済み利用者の DB と Pi のファイルを壊さない。変更量の少なさは判断基準にしない。
Server Account による同期は未リリースで、見直しの対象である。この計画は現行の同期契約を守る対象にしない。
複数のアカウントを使い分けている利用者はいない。移行は 1 つのアカウントだけを引き継ぐ前提で設計する（いずれも 2026-11-23 にユーザーが確認）。

この計画はコードの読解と、開発者 1 名の Mac の実データ（件数のみ）に基づく。実行しての確認は各段階のテストで行う。

## 1. なぜ変えるか

アプリの「アカウント」は、開いている Workspace から導出される（`Models/CodexRuntimeContext.swift:14`）。
アカウントを切り替えると次が起きる。

- すべての Pi プロセスを終了する（`Services/PiRuntimeService.swift:146-171`）。
- 他アカウントの待機中の実行を中断し、セッションを閉じる（`Services/PiChatService+Subscriptions.swift:150-165`）。
- チャット一覧、カレンダー、会議設定、MCP の登録、モデル設定が、切り替え先のものに入れ替わる。

対話だけなら「開いているアカウントの AI だけが動く」は自然だった。常時実行はこの前提と両立しない。PR #840 で観測できる挙動は次のとおり。

| 挙動 | 根拠（PR #840 の worktree） |
| --- | --- |
| 取り込み・Router・タイマーは選択中アカウントの分だけ動く。他アカウントの Event は戻るまで滞留する | `PiChatService+AlwaysOn.swift:100-130` |
| 切り替えで実行中の取り込みと Router を止め、取り込み位置は進めない | 同 `:108-114`, `:195-201`、`PiChatService+DahliaBot.swift:110-114` |
| 定期実行と自己学習も選択中アカウントだけ | `Services/PiChatService+Learning.swift:251-275` |
| Databricks のサインアウトでは常時実行の行と設定が残り、Server アカウントの削除では消える | `ViewModels/WorkspaceAISettingsModel.swift:166-180`、`Database/MeetingRepository+DahliaAccounts.swift:25-49` |
| 「アカウントごとに同時 1 本」と書いた枠は、実装ではアプリ全体で 1 本 | `PiChatService.swift:23-31` |

同じ値（`accountKey`）が、Pi のディレクトリ、DB の `accountID`、UserDefaults の接尾辞、MCP の参照範囲を兼ねている。
「アカウント」を表す型も 4 つある（`CodexRuntimeProvider`、`AppAccountScope`、`AIAccountProvider`、`WorkspaceAccountChoice`）。
常時実行の機能を足すたびに、この 1 つの値に依存する箇所が増える。

## 2. 目指す形

**アカウントの操作で、動いている AI が止まらない。** これを設計の中心に置く。

| 概念 | 役割 | 個数 |
| --- | --- | --- |
| **アカウント** | この Mac の Dahlia の利用者。チャット履歴、メモリー、スキル、設定、常時実行はここに属する。サインインしていない状態か、Dahlia account でサインインした状態のどちらかである | 1 |
| **プロバイダーアカウント** | 外部への接続 1 件。認証情報と、提供する capability を持つ。Databricks はここに入る | 複数 |
| **capability** | プロバイダーアカウントが提供する機能の種類。下の表の 5 つ | 種類ごとに 0 以上 |
| **割り当て** | 利用先（チャット、要約、常時実行の Source、カレンダー）が、どのプロバイダーアカウントの capability を使うか | 利用先ごと |
| **Workspace** | Project・Meeting・ファイルの入れ物。アカウントには属さない | 複数 |

| capability | 内容 | 初期リリース |
| --- | --- | --- |
| `model` | 推論に使うモデル | 含む |
| `mcp` | エージェントが使う MCP サービス | 含む |
| `calendar` | 予定の取得（Google カレンダー） | 含む |
| `storage` | オブジェクトストレージ。バックアップと録音ファイルの保存に使う | 含まない。詳細は未定 |
| `database` | 行データの置き場所 | 含まない。詳細は未定 |

- アプリにログインするアカウントは、リリース予定の Dahlia account だけにする。サインインは任意で、録音・文字起こし・閲覧・検索はサインインなしで動く。
- Databricks は「アプリのアカウント」ではなくなり、プロバイダーアカウントとしてだけ扱う。ChatGPT、Anthropic、Google も同じである。
- 「切り替え」は無くなる。プロバイダーアカウントの追加・削除・再認証は、その capability を使っている実行だけに影響する。
- Workspace は一覧にすべて並ぶ。「アカウント間の移管」は無くなる。

### 現在の接続と capability

現行コードから起こした対応表。○ は現在使われているもの。Databricks は 5 つすべてに対応する。

| プロバイダーアカウント | model | mcp | calendar | storage | database | 認証の持ち主 |
| --- | --- | --- | --- | --- | --- | --- |
| ChatGPT サブスクリプション | ○ | | | | | Pi（`auth.json`）。行は持たない |
| Anthropic サブスクリプション | ○ | | | | | Pi（`auth.json`）。行は持たない |
| Databricks workspace（複数可） | ○ Gateway | ○ Unity Gateway | ○ Google Calendar の proxy | 対応予定（未実装） | 対応予定（未実装） | Desktop（Keychain、`provider_accounts` 行） |
| Google | | | ○ | ○ Google Drive。現在はバックアップの読み取りだけ | | Desktop（Keychain、`provider_accounts` 行） |
| Dahlia Server（未リリース、見直し対象） | Gateway | | | Workspace の同期、音声アーカイブ | 同左 | Desktop（Keychain、既存の行） |

- プロバイダーアカウントの台帳は、既存の `accounts` テーブルを `provider_accounts` に改名して使う（新しい migration で改名する）。
- プロバイダーアカウントは表示用の名前を持てる。`provider_accounts` に任意の `name` 列を足し、利用者が設定で付け替えられるようにする。
  未設定のときは今と同じ「ホスト名の先頭 (メールアドレス)」を表示する。名前は表示だけに使い、プロバイダー ID や認証情報の参照には使わない。
  Pi が認証を持つ ChatGPT と Anthropic は行がないので、名前は付けられない。
- 認証情報の持ち主は、Pi の外でも使うかで決める。
  - **アプリが持つ（Keychain と `provider_accounts` の行）**: Databricks と Google。モデル以外の capability（MCP、カレンダー、ストレージ）を Pi の外の機能と共有するためである。Pi には要求のたびに token を渡す。
  - **Pi が持つ（`auth.json`、行なし）**: ChatGPT と Anthropic のサブスクリプション。提供するのはモデルだけで、サインインの手順も Pi が実装している。アプリ側に同じ認証を作り直す理由がない。
  - 設定の「プロバイダーアカウント」の一覧には両方を並べる。Pi が持つものは、Pi のサインイン状態から表示する。
  - 後からモデル以外の capability を持つことになったプロバイダーは、その時点でアプリ側へ移す。
- Google は `calendar` と `storage`（Google Drive）を持つプロバイダーアカウントにする。認証は 1 つのプロバイダーアカウントに 1 つだけ持ち、必要な権限は capability を使い始めるときに同じ認証へ足す。
  現在は Keychain にカレンダー用と Drive 用のセッションを別々に持ち、台帳の行がない。この 2 つは引き継がず、アップデート時に削除して再サインインを求める。
  直接の Google 接続でカレンダーと Drive を使っている利用者はほぼいないため、破壊的な変更を許容する（2026-11-23 にユーザーが確認）。Databricks 経由のカレンダーは Databricks の認証を使うので、影響を受けない。
- capability は種別ごとにコードで決まる値とし、テーブルに保存しない。モデル一覧や MCP の一覧は今までどおり接続先から取得する。
- Databricks の接続は 1 系統にまとめる。現在は「Desktop が認証する接続」と「Pi が認証する追加 workspace」の 2 系統がある。
  認証情報はすべてアプリ側（Keychain）に持ち、Pi には要求のたびに token を渡す。`calendar` など Pi の外の機能と同じ認証を共有するためである。
  Pi のプロバイダー ID は、どの接続も「追加 workspace」と同じホスト名にする。
- macOS のカレンダー（EventKit）は OS の権限であり、プロバイダーアカウントにしない。Web 検索のキーも今回は対象外。
- Dahlia account 自身が capability（Gateway のモデルなど）を提供するかは、この計画では決めない。

## 3. 何が変わるか

### 移行: Local Account を引き継ぎ、Databricks アカウントのデータを移す

アカウントの概念は無くなるので、アプリの唯一のアカウントは今の Local Account を引き継ぐ（2026-11-23 にユーザーが決定）。
実行アカウントは常に Local になり、Databricks の接続は Local が使うプロバイダーアカウントになる。
最後に開いていた Workspace が Databricks アカウントのものなら、そのアカウントのデータを 1 回だけ Local へ移す。
複数のアカウントを使い分ける利用者はいないので、移す元はこの 1 つだけにする。最後に開いていた Workspace は `workspaces.lastOpenedAt` から必ず 1 つに決まる。

| 対象 | 移し方 | Local 側と衝突したとき |
| --- | --- | --- |
| DB の `accountID`（スレッド、定期実行、メモリー、スキルの状態など） | 移す元の接続 UUID を `local` に書き換える | スレッドやメモリーは並べて残す。主キーに `accountID` を含む行（スキルの状態）は移す元を採る |
| `workspaces.databricksConnectionId` | すべて空にする。Workspace はどのアカウントにも属さなくなる | なし |
| UserDefaults（モデル、MCP の登録、カレンダー、会議設定、手引きなど） | `<名前>.<UUID>` を `<名前>.local` へ写す | 移す元を採る（実際に使っていた側なので） |
| Keychain の Pi 起動用の環境変数 | Local のキーへ写す | 移す元を採る |
| Pi のディレクトリ | 下の「Pi のディレクトリ」 | 同 |
| 保存済みのプロバイダー ID `databricks` | 接続が 2 つ以上になる段階で、ホスト名 ID へ置き換える。対象は下の表 | なし |

Pi のディレクトリ:

- アカウントごとの `accounts/<local または UUID>/pi` をやめ、`Application Support/Dahlia/agent` の 1 つにする。
  Pi 以外のエージェントに替わっても使えるよう、名前に `pi` も `local` も含めない（2026-11-23 にユーザーが決定）。
- 移す元（Databricks アカウントがあればそのディレクトリ、なければ `accounts/local/pi`）を `agent` へ写す。
  Databricks アカウントから写すときは、`accounts/local/pi` の ChatGPT・Anthropic のサインイン（`auth.json` のその項目）と、
  移す元に無いセッション・スキルも加える。同名のスキルは移す元を採る。
- 元のディレクトリは 1 リリース残す。写し終えるまで移行済みにしないので、途中で失敗しても次の起動で元から写し直せる。

DB の `accountID` と UserDefaults の接尾辞には、当面 `local` を定数として残す。アカウントが 1 つなので意味は持たない。

移行で書き換えるので、前回のレビューの衝突の指摘（他の接続の MCP 登録、同名スキル）は上の表の規則で扱う。
既存の定期実行は、すべての Workspace を読めるようになる（下の「受け入れる変化」）。

旧 ID `databricks` を保存している場所と、置き換えの内容:

| 場所 | 置き換え |
| --- | --- |
| `chat_threads.model`、`chat_runs.model`、`agent_reviews.model`、UserDefaults のモデル設定 | `databricks/<モデル名>` の接頭辞 |
| MCP の登録（UserDefaults の `agentMCPs.<key>`） | `providers[].id`、`servers[].providerID`、`listedServices` と `serviceComments` の辞書キー。Pi に書き出す `mcp.json` の `auth.provider` はこの値から作られる（`Models/AgentMCPSettings.swift:138-142`） |
| 常時実行の Source と Worker の許可（PR #840、未リリース） | 接続の照合キー `server.id|providerID|url` に含まれるプロバイダー ID。置き換え後も同じ登録を指すので、許可は引き継ぐ |

受け入れる変化（複数アカウントを使い分ける利用者がいない前提による）:

- 移す元にしなかったアカウントのデータは、画面に出なくなる。データは Mac に残す。
- すべての Workspace が一覧に並び、チャットと既存の定期実行から読めるようになる。
- Databricks の接続を削除しても、履歴と設定は Local に残る。

### Workspace と画面

| 項目 | 現在 | 移行後 |
| --- | --- | --- |
| `workspaces.databricksConnectionId` | Databricks アカウントへの所属。一覧の絞り込みと実行アカウントの導出に使う | 段階 3 で列を削除する（新しい migration を足す。リリース済みの migration は変更しない） |
| `workspaces.accountConnectionId` | Server アカウントへの所属。同期先を兼ねる（未リリース） | 実行アカウントの導出には使わない。段階 4 で、現行の Server 同期のコードと同時に削除する |
| Workspace の一覧 | サイドバーでアカウントごとに絞る | すべて表示する |
| Local ⇄ Databricks の移管、アカウントごとの `Default`、「ローカルアカウントを非表示にする」 | あり | 削除する |
| サイドバーのアカウントメニュー | Local と Databricks アカウントを並べて切り替える | Dahlia account のサインイン状態だけを示す。Dahlia account のリリースまでは表示しない |
| Databricks のサインイン | アカウントメニューとセットアップツアー | 設定の「プロバイダーアカウント」とセットアップツアー（任意の手順） |

### 設定画面

プロバイダーアカウントの管理は、設定の「機能」グループの「プロバイダー」ページに独立させる（2026-11-23 にユーザーが提案）。

| ページ | 置くもの |
| --- | --- |
| プロバイダー | プロバイダーアカウントの一覧と管理: 追加、サインイン・再サインイン、名前の変更、サインアウト・削除、各アカウントが提供する capability の表示。並べるのは ChatGPT・Anthropic（Pi がサインインを持つ）、Databricks の接続、以前に追加した workspace（再サインインで接続になる）、Google |
| エージェント → モデル | プロバイダーごとのモデルのオン・オフ。アカウントの操作は「プロバイダー」ページへ案内する |
| カレンダー | 予定を読むプロバイダーの選択と、表示するカレンダー。macOS カレンダーは OS の権限なのでここに残す |

### 実行

- Pi のプロセス、チャット、定期実行、自己学習、常時実行は、アカウントに 1 組だけ持つ。`currentProvider()` と開いている Workspace に依存する分岐を無くす。
- token の受け渡しは、実行アカウントではなくプロバイダー ID（ホスト名）から接続を引く（`PiRuntimeService.resolveToken` の `switch` を置き換える）。モデル、MCP、カレンダーが同じ接続の token を使う。
- サインインしていない利用者も、Databricks をプロバイダーアカウントとして足せば、ChatGPT・Anthropic と並べて使える。
- カレンダーは、Google の直接接続と Databricks 経由のどちらを使うかを割り当てで選ぶ。今は実行アカウントの種類で決まっている。
- 常時実行の Source と Worker の許可は、「プロバイダーアカウント + MCP サービス」に結び付ける。現在の `server.id|providerID|url` の照合をそのまま使い、再登録しても許可を引き継がない。

## 4. 残る反論

1. **接続をまたぐ操作が 1 つの実行に同居する。** Gmail を読む接続と、書き込める別の接続を同じ Worker が持つと、
   メールに埋め込まれた指示が別の接続への操作を引き起こせる。常時実行の「タスクごとの許可」をプロバイダーアカウント単位で維持する必要がある。
2. **個人のモデルへ送れる範囲が広がる。** Databricks アカウントで使っていた利用者が ChatGPT を足すと、同じ Workspace の内容を個人のサブスクリプションへ送れる。
   今は Databricks アカウントに ChatGPT を足せないので、この組み合わせは起きない。どのモデルを使うかは利用者が選ぶものとし、規則は置かない（6 章の判断 3）。
3. **Dahlia account がまだ無い。** ログインを Dahlia account だけにすると、リリースまでの間、アプリには「ログイン」が存在しない。
   Databricks でサインインしていた利用者には、サインインの場所が設定へ移ったことを案内する必要がある。

## 5. 段階と完了条件

各段階は単独でマージでき、前の段階までの挙動を壊さない。

| 段階 | 内容 | 完了条件（自動で確かめるもの） |
| --- | --- | --- |
| 0 判断 | コードは変えない。6 章の判断を得る | 判断 3 件がこの計画に書かれている |
| 1 capability の参照 | プロバイダーアカウントと capability を引く入口を 1 つ作り、実行アカウントで分岐している約 19 箇所を置き換える。挙動は変えない | 既存の全テストが変更なしで通る。`switch` で実行アカウントを分岐する箇所が入口の 1 箇所だけになる |
| 2 実行の単一化 | `accounts` を `provider_accounts` に改名し、`name` 列を足す。実行アカウントを常に Local にし、Databricks アカウントのデータを Local へ移す。Pi のディレクトリを `agent` の 1 つにする。アカウント切り替えで Pi を止める経路を削除する | Databricks と Local の両方にデータを持つ fixture を上げ直す。移す元のスレッド・定期実行・メモリー・スキル・MCP 登録・モデル設定が Local で見え、件数が一致する。Local の ChatGPT・Anthropic のサインインが残る。元のディレクトリと行は残る。移行の途中で失敗しても、次の起動で同じ結果になる。すべての Workspace の `databricksConnectionId` が空になる。Workspace を開き直しても Pi のプロセス ID が変わらない |
| 3 Workspace の切り離しと割り当ての UI | Workspace をすべて表示にし、`workspaces.databricksConnectionId` を削除する。Google を 1 つの認証を持つプロバイダーアカウントにし、既存の 2 つのセッションを削除する。移管・非表示設定・アカウントの切り替えを削除する。設定に「プロバイダーアカウント」の一覧を置き、モデル・MCP・カレンダーを capability から選ぶ。チャットの `dahlia-mcp` から `--account` の固定を外す | サインインしていない状態に Databricks を 2 つ足し、1 つのスレッドで ChatGPT と両方の Databricks のモデルを切り替えられる。Pi の `auth.json` に Databricks の認証が書かれない。Google に 1 回サインインすると、カレンダーの取得と Drive のバックアップ読み取りの両方が同じ認証で動く。Databricks 経由のカレンダーは、アップデートの前後で再サインインなしに表示され続ける。プロバイダーアカウントの追加・削除・再認証の間、別の接続のモデルを使う実行が中断しない。接続を削除すると、その割り当てだけが「再設定が必要」になる。同じ種類の接続 2 つに別の名前を付けると、モデルと MCP の選択肢でその名前で見分けられる。外部から `--workspace` で範囲を固定した `dahlia-mcp` は、今までどおり範囲の外を読めない |
| 4 片付け | 4 つのアカウント型を 1 つの固定キーに置き換える。現行の Server 同期のコードと `workspaces.accountConnectionId` を削除する（2026-11-23 にユーザーが承認）。spec・用語集・PRODUCT.md（承認後）を書き換える | `CodexRuntimeProvider` の参照が 0（現在 Sources 59 ファイル、Tests 26 ファイル）。`accountConnectionId` の参照が 0（現在 Sources 75 ファイル、Tests 59 ファイル）。全テストが通る。`node scripts/check-docs.mjs` が通る |

### 進捗

| 段階 | 状態 |
| --- | --- |
| 1 | 実装した。`Models/ProviderAccount.swift` が capability の入口で、token の要求は Pi が送るプロバイダー ID から接続を引く。機能が接続を選ぶ箇所（Pi のプロバイダー ID、`models.json` の書き出し、Gateway の一覧、Omnigent、カレンダーの proxy、MCP の設定）を置き換えた。画面の分岐（アカウント名の表示、Workspace の所属）は段階 3 で画面ごと消すので残した。`accountKey` の導出は段階 4 で消す |
| 2 | 実装した（未コミット）。`v67_providerAccounts` で `accounts` を `provider_accounts` に改名し `name` 列を足した。実行アカウントは常に Local で、Databricks の接続を Local のプロバイダーアカウントとして使う。起動時の移行（`Services/SingleAccountMigration.swift`）が、Databricks アカウントのデータを Local へ写し、すべての Workspace の `databricksConnectionId` を空にする。Pi のディレクトリは `agent` の 1 つにした。アカウントメニューの Databricks の一覧と切り替え、サインイン後の移管・作成、Workspace 設定の移管とアカウント別のグループ、「ローカルアカウントを非表示にする」を削除した。Databricks の接続のサインアウトは設定のプロバイダー一覧へ移した |
| 3 | 未着手。残りは下の「段階 3 の残り」 |

#### 段階 4 の進捗

- 実装した（2026-11-23）: 実行アカウントの `.databricks` と `WorkspaceAccountChoice.databricks`、`WorkspaceRecord.databricksConnectionId` の参照、アカウントメニューの Databricks の分岐を削除した。`workspaces.databricksConnectionId` の列は、外部キーごと消すには表の作り直しが要るので DB に残し、起動時に空にする。外部の `dahlia-mcp --account` に Databricks の接続を指定すると、黙って空にせず失敗する。
- 残り: 現行の Server 同期のコードと `accountConnectionId` の削除。旧ディレクトリと旧設定キーの削除（1 リリース後）。

#### 段階 3 の残り

- 実装した（2026-11-23）: Databricks の接続ごとのプロバイダー ID（ホスト名）。アカウントはすべての接続を同時に使う。保存済みの `databricks`（モデル指定、MCP の登録、Gateway のモデル一覧）は起動時に 1 回、移す元の接続のホスト名へ置き換える。
- 実装した（2026-11-23）: 「プロバイダーを追加」はアプリ側のサインインで接続（プロバイダーアカウント）を作る。以前に追加した workspace は Pi のサインインのまま動き、同じホストの接続を追加するとアプリ側の認証が優先される。
- 実装した（2026-11-23）: Google のカレンダーと Drive は 1 つのサインインを共有し、Drive もカレンダーと同じ Google の選択に従う。用途ごとの以前のサインインは起動時に削除する。Google の `provider_accounts` の行は、プロバイダーアカウントの一覧を作るときに足す。
- 実装した（2026-11-23）: 表示名の編集。設定のエージェントのプロバイダー一覧（接続ごとの行）で名前を変え、一覧・モデルの選択・カレンダー・サインアウトの確認に出す。モデルと MCP は、その一覧の接続ごとの行で選ぶ。
  カレンダーは実装した（2026-11-23）。設定のカレンダーでプロバイダー（macOS カレンダー、Google、Databricks の接続）を折り畳んで並べ、Google カレンダーは Google か Databricks の接続のどちらか一方から読む（`Models/GoogleCalendarProvider.swift`）。macOS カレンダーは OS の権限なので `provider_accounts` に置かない。
- 実装した（2026-11-23）: 接続の追加・削除で Pi を止めない。設定ファイルを書き直し、待機中のチャットは閉じて次の送信で開き直す。実行中のチャットはターンの終了後に閉じる。
- `dahlia-mcp` の `--account` を外す。今も `--account local` は Server 以外のすべての Workspace を対象にする（所属を空にしたため）。

目標: アップデートで再サインインを求める回数 0、移す元のアカウントで失われるスレッド 0、アカウント操作が原因で常時実行が止まる時間 0 秒。
移行は元を残して写すので、3 つとも stretch ではなく完了条件として扱う。例外は 2 つで、どちらも 1 回だけ再サインインを求める。追加 workspace（認証を Keychain へ移す）と、直接の Google 接続（2 つのセッションを 1 つの認証にする）である。

### 確認済み

- 1 つの Pi プロセスで、Desktop が token を渡すプロバイダーを複数扱える。拡張は token の要求にプロバイダー ID を付けて送っている（`PiExtension/dahlia.ts:123`）。
  アプリ側は今この ID を読まず、実行アカウントの token を返している（`Services/PiRuntimeService.swift:112-114`）。段階 1 で、受け取った ID から接続を引くように変える。
  Pi が認証する ChatGPT などは別の経路なので、同じプロセスに同居できる。静的に読んだ結果で、実行しての確認は段階 1 のテストで行う。
- token の scope は `all-apis` に統一する（2026-11-23 にユーザーが決定）。
- 移す元のアカウントは 1 つに決まる。`workspaces.lastOpenedAt` は NOT NULL で、起動時もこの列の降順で開く Workspace を選んでいる（`Database/MeetingRepository.swift:70`）。

### 実データの確認

開発者 1 名の Mac（v1.9 系、件数のみ）: `accounts` 行は Databricks 1 件。スレッドは Databricks 17 件、Local 1 件。Workspace は Databricks 1 件、Local 2 件。
この Mac では Databricks アカウントのスレッド 17 件を Local へ移し、Local のスレッド 1 件と並べる。すべての Workspace が一覧に並ぶ。
`accounts/` 以下の Pi ディレクトリは 4 つあり、うち 2 つは台帳に無い接続のものだった。移す元ではないので、これらには触れない。

### PR #840 との順序

この改修を先に進め、PR #840 は後からこの改修に合わせる（2026-11-23 にユーザーが決定）。この改修は #840 の変更を前提にしない。
#840 の migration は `v68` 以降に振り直す。#840 の `accountID` 列は、移行の対象（`accountID` を持つ表）に加える。

## 6. 判断が要る点

| # | 判断 | 推奨 | 理由 |
| --- | --- | --- | --- |
| 1 | アプリにログインするアカウントを Dahlia account だけにし、Databricks をプロバイダーアカウントとしてだけ扱うか | そうする | Databricks が提供するものは 5 つの capability で表せる。ログインと接続を分けると、アカウントの種類による分岐が消える |
| 2 | 移行は Local Account を引き継ぎ、最後に使っていた Databricks アカウントのデータを Local へ移すか | そうする（2026-11-23 にユーザーが決定） | アカウントの概念が無くなるので、キーは接続に結び付かない値がよい。複数アカウントを使い分ける利用者がいないので、移す元は 1 つでよい |
| 3 | モデルごとに読める Workspace を制限する規則を置くか（4 章の反論 2） | 置かない。共有される Workspace の規則は、同期の実装を決めるときに合わせて決める | リリース済みの Workspace はすべて Mac にある。先に規則を作ると、同期の設計を縛る |

プロダクトの原則に関わる変更が 2 件ある。どちらも承認を得てから PRODUCT.md を直す。

- PRODUCT.md:142 の「選択中アカウントの読み取り専用の定期実行」は、「選択中アカウント」という条件が意味を失う。
- PRODUCT.md:160-163 と用語集の「Local Account / Server Account」は、Server を正本とする同期を前提に書かれている。同期の実装が決まった時点で、この記述ごと書き換える必要がある。

T4（他サービスへの連携を Dahlia に実装しない）には抵触しない（2026-11-23 にユーザーが確認）。
T4 が禁じるのは、Salesforce のように企業ごとに使い方が異なる個別のサービスへ、Dahlia が個別に対応することである。
`storage` のように Dahlia の基本機能をアダプターで抽象化したものは、これに含まれない。

## 7. `storage`・`database` と同期

初期リリースに含めるのは `model`・`mcp`・`calendar` である。`storage` と `database` は capability の種類として定義だけ置き、設定項目と実装は決めない。
同期の実装も未定である。

- `storage` はオブジェクトストレージで、バックアップの保存と録音ファイルの保存に使う想定である。
- `database` の用途と、同期をどの capability の上に作るかは未定である。
- この計画が保証するのは 1 点である。`storage`・`database` を後から足すとき、プロバイダーアカウントと割り当ての仕組みを作り直さずに済む。
  段階 1 の入口は capability の種類を増やせる形にし、段階 3 の設定画面は種類ごとの割り当てを並べる構成にする。

## 8. やらないこと

- Gemini を Google のプロバイダーアカウントの `model` として扱うこと。Databricks の Gateway 経由の Gemini は今までどおり使える。
- 同期の設計と実装、`storage`・`database` の設定項目と実装。
- 複数アカウントのデータの統合。引き継がないアカウントのデータは Mac に残すが、画面には出さない。
- Dahlia account のサインイン自体の実装。リリース時期に合わせて別に進める。
- capability を保存するテーブル、プラグイン式のプロバイダー登録。種別は 5 つで、コードの表で足りる。
- Electron alpha、Desktop v2、Web への展開。
- アプリを終了している間の常時実行。

## 9. 書き換える仕様（段階 4）

[Desktop の認証と account 分離](../spec/desktop/accounts.md)、[アカウント別の Desktop 推論](../spec/shared/account-scoped-desktop-inference.md)、
[定期エージェント](../spec/desktop/scheduled-agent-scope.md)、[自己学習](../spec/desktop/pi-self-learning.md)、
[Local MCP と Project](../spec/desktop/local-mcp-and-projects.md)、[内蔵 Pi runtime](../spec/desktop/pi-runtime.md)、
常時実行の仕様（PR #840 で追加）、`AGENTS.md` の用語集。
[同期契約](../spec/shared/sync.md) と [Organization と個人 Workspace](../spec/shared/organization-personal-workspaces.md) は、Desktop の同期のコードを削除する段階 4 で、Desktop に関する記述を現状に合わせる。
