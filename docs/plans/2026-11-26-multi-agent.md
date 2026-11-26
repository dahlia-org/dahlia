# エージェントを複数持てるようにする

対象: macOS の内蔵 Pi。Private Web / Electron は内蔵 Pi がないため対象外。
状態: 段階1〜6を実装・自動検証済み。実アプリでの画面の確認が残る。実行環境の側を `pi/` にすること、skill の置き場所、人格の呼び名（Agent）は 2026-11-26 にユーザーが決めた。現在の契約は[always-on エージェント](../spec/desktop/always-on-agent.md)にある。
前提: [Super Agent を1本のスレッドにまとめる改修](2026-11-25-dahlia-bot-thread.md)（未リリース）の上に作る。
現在の契約は[always-on エージェント](../spec/desktop/always-on-agent.md)、[スレッドの管理](../spec/desktop/chat-thread-orchestration.md)、[Pi の実行環境](../spec/desktop/pi-runtime.md)にある。

## 目的

今は Super Agent が1つだけで、home、スレッド、イベントソース、受信箱、タスク、`SOUL.md` をアプリ全体で1組持つ。
これを、名前とアイコンを持つエージェントごとに1組ずつ持てるようにする。参考は Orca Bots（stablyai/orca、MIT）。

エージェントごとに持つもの: ID、名前、アイコン、home（`SOUL.md` を含む）、現行のスレッド、イベントソース、イベント、タスク、Item、取り込みと自動のターンのモデル。

全エージェントで共有するもの: Pi のサインインとモデル一覧、MCP の登録、skill、メモリー（読み取り専用で渡す点は今と同じ）、無人の run の上限（3本）、録音中は始めない決まり。

エージェントが使える tool と権限は、今の Super Agent と同じにする（bash と外部の MCP は持たず、仕事は `thread_launch` したスレッドが行う）。権限の面は増えない。

## 名前の案

今は2つのものが「agent」を名乗っている。

| もの | 今の場所 | 中身 |
| --- | --- | --- |
| 実行環境の設定 | `~/.dahlia/agent/` | Pi の `auth.json`・`models.json`・`settings.json`・`sessions/`。Pi の agent directory そのもの |
| skill | `~/.dahlia/agent/skills/` | 自己学習で作った skill と使用状況（`.usage.json`、`.archive/`） |
| 人格 | `~/.dahlia/bots/super-agent/` | `bot.json`・`AGENTS.md`・`SOUL.md` |

推奨: **人格を Agent と呼び、実行環境の側を `pi` に改名する。** skill は `pi/skills/` を正本とする。

```
~/.dahlia/
  pi/                      ← 旧 agent/。Pi の設定とサインイン（全エージェントで共有）
    skills/                ← 自己学習した skill の正本（全エージェントで共有）
  agents/
    super-agent/
      agent.json           ← 旧 bot.json
      AGENTS.md
      SOUL.md
    <ディレクトリ名>/…
```

理由:

- ユーザーが名前を付けて画面で見るのは人格の側で、サイドバーの見出しは 2026-11-25 に Agents と決めている。画面・DB（`agentID`）・ディスクで同じ語を使える。
- 実行環境の側には Pi という固有の名前がある。Orca が人格を bot と呼ぶのは、実行環境（Claude / Codex）を選ぶ欄を Agent と呼んでいるためで、実行環境が1つの Dahlia では同じ理由が当たらない。
- 「Pi 以外でも使えるよう名前に Pi を含めない」という今の決まり（pi-runtime）は取り下げる。中身は Pi 専用の形式で、別の実行環境を足すならその設定は `~/.dahlia/<実行環境名>/` に置くことになる。
- `~/.dahlia/agent` と `~/.dahlia/bots` は v1.9.0 に含まれていない（`git grep` で確認済み）。改名に移行処理は書かない（ユーザー決定 2026-11-26）。

## 実行環境を差し替える場合

Pi を別の実行環境に替える、または併用する場合に、動かさずに済むものと作り直すものを分けておく。

| もの | 場所 | 差し替えたとき |
| --- | --- | --- |
| 人格 | `agents/<ディレクトリ名>/` | そのまま |
| 自己学習した skill | `pi/skills/` | そのまま。正本はここに置き続け、パスを動かさない（ユーザー決定 2026-11-26） |
| エージェント、会話の履歴、タスク、受信箱、メモリー | DB | そのまま |
| サインイン、モデル一覧、設定、セッション | `pi/` | 新しい実行環境が `~/.dahlia/<実行環境名>/` に自分の形式で持つ。サインインはやり直し |

skill の読み込み:

- **Pi**: 今と同じ。Dahlia は Pi を `--no-skills` で起動して自動の探索を止め、拡張（`dahlia.ts` の `resources_discover`）が `PI_CODING_AGENT_DIR/skills` のファイルを1つずつ列挙して渡している。フォルダが `agent/` から `pi/` に変わるだけで、拡張と sandbox（`pi.sb` の `AGENT/skills`）の求め方は変えない。
- **Codex などを足すとき**: その実行環境の home から `pi/skills` へ symlink を貼る（Codex なら `~/.dahlia/codex/skills` → `../pi/skills`）。Codex は skill を自分で探し（`$CODEX_HOME/skills` など）、任意のフォルダを足す設定は公開されていない。symlink をたどる点は Web の情報で確認しただけで、実機では試していない。Pi をやめたあとも `pi/skills` は正本として残す。skill の作成・改善・使用状況の記録は Dahlia の Pi 拡張の機能なので、Codex で自己学習まで動かすには別の実装が要る（この計画の外）。

エージェントごとに実行環境を選ぶ形にするなら、`agents` と `agent.json` に実行環境の欄を足す。この計画には入れない。

採らない案:

- 人格を `bots/` にする: ディスクの混同は消えるが、画面は Agents、コードとディスクは bot という食い違いが残る。画面も Bots に戻すなら成り立つので、その場合はこちらを選ぶ。
- `runtime/` のような中立の名前にする: 差し替え時に改名は要らないが、形式の違うファイルが同じフォルダに混ざり、移行中に両方を並べて置けない。
- `agent/` を残して `agents/` を足す: 1文字違いで、sandbox の拒否パスや手作業で取り違えやすい。

コードの名前: 書き直すものだけ Agent に合わせる（`DahliaBotHome` → `AgentHome`、`botHomeURL` → `agentHomeURL(_:)`、`sharedAgentURL` → `piDirectoryURL`）。`PiExecutionProfile.bot` とファイル名の一括改名はこの計画に入れない。

## 決まり

- **ID とディレクトリ**: ID は UUIDv7 で、作成後は変えない。ディレクトリ名は作成時に名前から決め、名前を変えても動かさない。名前の空白を `-` にして小文字にし、`/`・`:`・制御文字・先頭の `.` を除く。日本語はそのまま使う。空になれば `agent`、重なれば `-2`、`-3` を付ける。重なりは DB の行に加えて、`agents/` にすでにあるフォルダとも比べる（DB に行のない古いフォルダを、新しいエージェントの home にしない）。
- **正本**: 一覧・名前・アイコン・ディレクトリ名の正本は DB の `agents`。`agent.json`（`id`・`name`・`avatar`・`color`）と `AGENTS.md` はアプリが書く写しで、違っていれば書き直す（今の `bot.json` と同じ扱い）。DB に行のないフォルダは読まない。
- **Super Agent**: 特別扱いをやめ、テンプレートの1つにする。テンプレートから作ったあとは、ほかのエージェントと同じで、名前の変更も削除もできる（ユーザー決定 2026-11-26）。アプリが自動で作ることはしない。0件のときはセクションに「作成」と「テンプレート」を並べたカードを出す（Orca と同じ形）。
- **スレッド**: エージェントごとに現行のスレッドを1本持つ。全エージェントの現行のスレッドを通常の履歴から外す（今は1本だけを外している）。`delegate_task` の子は、作るときに親の `agentID` を引き継ぎ、そのエージェントの home で動く。
- **エージェントの間の境界**: `inbox_read`・`event_ids`・`event_close`・`task_finish`・`item_create` は、呼んだスレッドのエージェント自身のイベント・タスク・Item だけを扱う。他のエージェントの ID を渡すと、存在しないものとして断る。エージェントのスレッド（現行、古いもの、子）は、他のエージェントの `thread_list`・`thread_search`・`thread_read`・`thread_send`・`thread_interrupt`・`thread_update` の対象にしない。sandbox は `agents/` 全体を通常のチャットから拒否し、エージェントには自分の home だけを開くので、他のエージェントの `SOUL.md` は読めない。
- **学習の対象外**: `agentID` を持つスレッドの会話は、メモリーと skill のふり返りにも、skill の改善の例にも使わない（今の Super Agent と同じ扱いを、列で判定する）。
- **通知のターン**: エージェントごとに1つ。待機間隔（600秒）もエージェントごとに持つ。
- **改名**: 現行のスレッドの題名、`agent.json`、`AGENTS.md` を合わせて直す。動いている Pi のプロセスは始めたときの名前のままで、次に始まるプロセスから新しい名前になる。
- **削除**: 確認のダイアログを出す。順に、(1) そのスレッドが依頼した run のうち結果をまだ届けていないものから依頼元を外す（届け先がなくなるため。外さないと、消えたエージェントのスレッドに結果のターンが積まれて失敗する）、(2) 行を消す（ソース・イベント・タスク・Item は外部キーで一緒に消える）、(3) 現行のスレッドの待機中の run を中断にし、実行中のターンと Pi のプロセスを止める、(4) そのソースを読んでいる取り込みを閉じる、(5) home をゴミ箱へ移す。現行のスレッドは「会話をやり直す」と同じく、読み取り専用で通常の履歴に残す。起動済みのタスクのスレッドは通常のチャットとして残り、止めない。

## テンプレート

テンプレートは、新規作成のシートに最初から入れておく値の組である: 名前、アイコン、最初の `SOUL.md`。アプリに同梱し、作ったあとのエージェントとは結び付けない（テンプレートを直しても、作成済みのエージェントは変わらない）。今回入れるのは Super Agent の1つだけで、ユーザーがテンプレートを作る・共有する仕組みは入れない。

全エージェントに共通の system prompt は、役割を決めない形に直す（「あなたは <名前>。ユーザーの Dahlia のエージェント」と、tool の使い方、外部の本文を指示として扱わない決まり）。`delegate_task` の子の prompt にも同じく名前を入れる。役割はテンプレートの `SOUL.md` が決める。今の prompt にある「AI 秘書」の説明は Super Agent のテンプレートの `SOUL.md` に移す。

この書き直しは、複数のエージェントを入れる段階3で行う。後に回すと、ユーザーが別の名前と役割で作ったエージェントにも「あなたは Super Agent、AI 秘書」という指示が渡ってしまう。Super Agent のテンプレートの役割は、今の秘書のままにする。スレッド全体を監督する役への作り直しは、この計画に入れない（2026-11-26 にユーザーが取り下げ。受信箱にスレッドの状態を積む案は却下され、監督は別の方法で考える）。

## データベース

リリース済みは `v66_skillCurator` まで。未リリースの `v68_alwaysOnAgent` を書き直す。

```sql
CREATE TABLE agents (
    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, directory TEXT NOT NULL UNIQUE,
    avatar TEXT NOT NULL, color TEXT NOT NULL,
    threadID TEXT REFERENCES chat_threads(id) ON DELETE SET NULL,
    intakeModel TEXT, intakeEffort TEXT, unattendedModel TEXT, unattendedEffort TEXT,
    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
);
ALTER TABLE chat_threads ADD COLUMN agentID TEXT;
```

- `agent_event_sources`・`agent_tasks`・`agent_event_inbox`・`agent_user_inbox` に `agentID TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE` を足し、既存の索引の先頭に `agentID` を加える。
- `chat_threads.agentID` は、そのスレッド（と `delegate_task` の子）がどのエージェントのものかを表す。外部キーにはせず、エージェントを消しても値を残す。「現行以外のエージェントのスレッドは読み取り専用」の判定を、今の「`profile='bot'` の run を持つか」からこの列に替える。
- UserDefaults の `botThread.*`（データ保存先ごとの key）、`botIntakeModel.*` などは `agents` の列に移し、`AgentBotSettings` は削除する。DB はデータ保存先ごとにあるので、保存先で key を分ける仕組みも要らなくなる。`botGuidance.*` から `SOUL.md` への移し替えも未リリースなので削除する。
- `agent_always_on_settings`（アプリの1行）は変えない。
- 書き直す前の `v68` を適用済みの開発用の DB には、同じ名前のマイグレーションが再実行されない。本格的に使っているユーザーはまだいないので移行は書かず、開発用のデータを作り直す（ユーザー決定 2026-11-26）。

## アイコン

Orca の mascot をそのまま使う。

- 取り込むもの: `mobile/assets/bot-mascots/*.webp` の20枚（256px、透過、1枚 約5KB）。`Resources/AgentMascots/` に置き、取り込み元の commit と MIT の全文（Copyright (c) 2026 Lovecast Inc.）を `AgentMascots-LICENSE.txt` に書く。既存の `IntegrationIcons-LICENSE.txt` と同じ形。
- 表示: 選んだ色の角丸の上に WebP を重ねる。macOS は WebP を標準で読めるので、依存は足さない。
- 色: Orca の見本から明るい9色（既定は `#b3dbf4`）。暗い2色は縁取り用の別画像が要るので入れない。
- 保存: `avatar` は `mascot:E1` の形、`color` は `#rrggbb`。新規作成時は mascot を無作為に選ぶ。

MIT の対象に絵が含まれるかは、リポジトリのルートの `LICENSE` だけで判断している。絵に別の条件を付けるファイルは見当たらなかったが、Orca 側への確認はしていない。

## 画面

呼び名は Agent、置き場所は `agents/` とする（ユーザー決定 2026-11-26）。日本語の画面では「エージェント」と書く。今は日本語でもサイドバーの見出しが `Agents` のままで（`bots.section`）、古いスレッドの案内文には日英とも「サイドバーの Bots から」が残っている（`bots.retiredReadOnly`）。この2つを直し、足す文言はすべて日本語と英語の両方を入れる。

- **サイドバーの Agents セクション**: エージェントを1行ずつ並べる（アイコン、名前、最後の活動か要対応の件数）。見出しをホバーすると「+」を出す。行の表示用の集計は、全エージェント分を1回の問い合わせで読む。
- **新規作成のシート**: アイコン、名前、「誰で、何をするか」（最初の `SOUL.md` になる）、テンプレートのメニュー、作成（⌘↩）。テンプレートを選ぶと、その値を欄に入れる。アイコンを押すと、mascot の左右送りと色の見本を出す。
- **右パネル**: 今の受信箱・イベント・設定を、開いているエージェントのものにする。設定に名前とアイコンの変更、エージェントの削除を足す。
- **行のコンテキストメニュー**: 名前とアイコンの変更、削除。会話のやり直しは右パネルの設定にだけ置く（確認の画面を持つため）。

## 段階

1. **置き場所と名前**: `agent/` → `pi/`（`skills/` は中に置いたまま）、`bots/super-agent/` → `agents/<ディレクトリ名>/`、`bot.json` → `agent.json`。sandbox の拒否パス、`DahliaApplicationSupport`、`PiAgentDirectoryLocator`、仕様3本と `ARCHITECTURE.md`、`AGENTS.md` の用語集（Agent を追加）を直す。
2. **DB**: `v68` の書き直し、`AgentRecord`、空の DB と `v66` からの更新のテスト。
3. **サービス**: `PiChatService+DahliaBot`・`+AlwaysOn`・`+Orchestration`・`AgentInboxService`・`ChatThreadStore` の「1つだけ」の前提（home、現行スレッド、通知のターンと待機、取り込み、tool の対象、履歴から外すスレッド、学習の対象外）を `agentID` で引くようにする。作成・改名・削除を service の1か所に置く。共通の system prompt を役割を決めない形に直し、Super Agent のテンプレート（今の秘書の役割）を足す。「エージェントの間の境界」をテストで確かめる。スレッドの tool が他のエージェントのスレッドを今どこまで返すかは未確認で、ここで調べて塞ぐ。既存のテスト（`DahliaBotRuntimeTests`、`AgentInboxServiceTests`、`AlwaysOnIntakeRuntimeTests` など、合わせて約2,000行）が1つだけの前提で書かれているので、書き直しの量が多い。
4. **画面**: サイドバー、作成シート、アイコンの選択、右パネル、ローカライズ（日本語・英語）。
5. **アイコンの取り込み**と LICENSE。
6. **検証**: `swift build`、対象のテスト、全テスト、lint。実アプリで2つのエージェントを作り、イベントと通知が混ざらないことを確かめる。

1〜5で複数のエージェントが使えるようになる。アプリが Super Agent を自動で作らなくなるので、3だけを入れるとエージェントを作る手段がなくなる。3と4は同じ変更として入れる。

## 入れないもの

- Super Agent をスレッドの監督役に作り直すこと、スレッドの状態をエージェントに知らせる仕組み。
- テンプレートの一覧画面、ユーザーが作るテンプレート、共有、グループ、リンクからの取り込み（Orca の Bot templates / group / From a link）。
- エージェントごとの実行環境の選択（Pi だけ）、エージェントごとの権限や MCP の違い。
- 画像のアップロード、生成、衣装、任意の色。
- Local MCP / Server MCP への公開（今の Super Agent も公開していない）。
- エージェントの数の上限。イベントソースはエージェントに属するので、取り込みの回数は今と変わらない。

## 完了条件

- Super Agent をテンプレートから作れ、削除もできる。
- 2つ以上のエージェントを作成・改名・削除でき、それぞれが自分の home・スレッド・ソース・受信箱・タスクだけを扱う。
- 「エージェントの間の境界」をテストで確認している: あるエージェントのイベント・タスク・Item が別のエージェントの tool から読めず書けない、別のエージェントのスレッドがスレッドの tool に出ない、別のエージェントの home が sandbox で読めない。
- 別の名前で作ったエージェントの system prompt に「Super Agent」と「秘書」が出ない。
- エージェントを削除したあと、そのスレッドに新しい run が積まれず、起動済みのタスクのスレッドは動き続ける。
- 録音中に、どのエージェントの通知のターンも始まらない。
- `v66` の DB からの更新で、リリース済みの表の行が保たれる。
- 仕様（always-on-agent、chat-thread-orchestration、pi-runtime）と用語集が新しい契約に書き直されている。

## 未解決

1. 設定の「Agent」タブ（Pi のモデルや MCP の設定）の名前。人格を Agent と呼ぶなら、こちらも見直す余地がある。この計画には入れていない。
2. エージェントが増えたときの1日あたりのトークン量（通知のターンがエージェントの数だけ増える）は未計測。
