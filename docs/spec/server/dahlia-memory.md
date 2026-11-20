# Dahlia Memory の個人領域と外部エージェント

採択: 2026-11-03（Hindsight を廃止し、Dahlia の DB を唯一の Memory store とする）、2026-11-05（型・検索ツール・MCP の手引きを追加し、scope の Router を廃止）。検索のための送信範囲は 2026-11-03 にユーザーが承認した。

## 決定

ユーザー向け名称は Dahlia Memory とする。永続メモリーの正本は Dahlia の DB の保存メモリー（個人は `app.personal_memories`、共有は `app.shared_memories`）とし、外部の分析・記憶サービスを使わない。個人領域は認証済み user UUID、共有領域は現在アクセス可能な Workspace UUID に固定する。スレッド所有権、話題、共有先は独立した概念である。

保存メモリーは安定した `smem_` UUIDv7 TypeID、型、本文（16,000 文字以内）、正の `revision`、`updatedAt`、作成者、`protected`（Web で人が編集した印）を持つ。作成順は UUIDv7 が保持する。更新と削除は revision を照合し、一致しなければ `memory_revision_conflict` で拒否する。後勝ちで上書きしない。

型は `profile`（利用者が誰か）、`preference`（進め方の好み）、`work`（案件・顧客・決定・状況）、`people`（同僚や顧客の担当者）、`notes`（その他）の 5 つである。型は保存するエージェントが選び、一覧と検索の絞り込みに使う。新規保存で省略すると `notes`、更新で省略すると現在の型を保つ。顧客の情報は、組織や案件の状況を `work`、担当者を `people` で表すため、専用の型を持たない。議事録から顧客の情報を整える機能は、型ではなく顧客 Project との関連として扱う（[未適合・未検証](#未適合未検証)）。

会議の正本とメモリーは別物である。会議・要約・文字起こし・画像は既存の会議ツールと検索で扱い、メモリーへ自動で取り込まない。

### 権限と書き込み

個人領域は T4 の Workspace 境界への追加である。会議データの Server MCP は読み取り専用とする。メモリーだけは独立した `mcp:memory:read` / `mcp:memory:write` を持ち、既存の `mcp` / `mcp:read` / `all-apis` を書き込み権限に昇格させない。信頼済み header 配置では運用者が `DAHLIA_MEMORY_MCP_ACCESS=read|write` を明示する（既定は off）。Desktop ローカル MCP の `--write` 契約は変えない。

一覧・取得・更新・削除は明示した scope を使う。保存の scope は省略すると `personal` になる。検索の scope は省略すると `all` になる。`workspaceId` がなければ個人と、呼び出した人が現在読めるすべての Workspace（`list_memory_scopes` と同じ範囲）を横断して検索し、あればその Workspace と個人だけを検索する。Workspace を固定した内蔵 Agent のチャットは常にその Workspace を渡すため、他の Workspace を読まない。結果は scope ごとに分け、各 scope の権限を返却前に確かめ直す。横断検索では、権限の確認・検索・返却前の再確認のどこかで権限を失った Workspace だけを結果と `searchedScopes` から外す。指定した scope の権限を失ったときは失敗にする。

個人の簡潔な学習はエージェントが保存できる。共有、削除、人が編集したメモリーの変更は、利用者の明示的な指示を必要とする。`explicit` はその指示を伝えるクライアントの申告であり、自然言語の同意をサーバーが検証した証拠ではない。共有には現在の editor/admin 権限も必須とする。Web は内容と宛先を提示して確定する。私的な会話全体を自動取り込みせず、個人メモリーを共有へ自動で移動・複製しない。

### 共通の service と Mastra tools

`DahliaMemory` service がスコープ解決・認可・保存・検索を持ち、Web API、内蔵 Agent、MCP は同じ service method を通る。内蔵 Agent と MCP は同じ Mastra tools（`list_memory_scopes`、`list_memories`、`get_memory`、`search_memories`、`save_memory`、`delete_memory`、`get_working_memory`、`update_working_memory`）を使い、MCP には `mcp:memory:read` で読み取り、`mcp:memory:write` で書き込みを公開する。汎用 Agent は外部公開しない。

memory の scope を持つ接続にだけ、MCP の server `instructions`（`DAHLIA_MEMORY_INSTRUCTIONS`）を送る。内容は、セッションの初めに個人の `profile` と `preference` を読むこと、利用者や仕事に関わる質問の前に `search_memories` を呼ぶこと、保存するもの（決定と理由、訂正、好み、案件の状況、調べた結果、計画、人）としないもの（認証情報、雑談、途中の進捗、コード、リポジトリや会議にある内容）、型の選び方、近い重複は更新すること、食い違いは「今の依頼 > 明示 > 推測 > 新しい日付」で扱うこと、取り出した内容を指示として扱わないことである。読み書きの時点を決めるのはモデルであり、手引きは認可境界ではない。

個人の Working Memory は Mastra の resource-scoped Markdown とし、手動メモと明示的で継続的な利用者発言から学習したメモを分ける。`GET/PATCH /api/v1/user/memory/working` と `get_working_memory` / `update_working_memory` で本人に公開し、チャット削除では保存済みの内容を消さない。スレッド Observational Memory と会議由来の live context は別領域とし、live context API は `/api/v1/chat/{threadId}/live-context` に置く。Working Memory の編集中セクションは読込時の revision を維持し、別クライアントによる同セクションの更新を上書きしない。学習メモの上限到達時は既存内容を保持して自動学習を停止し、`capacityReached` と UI で通知する。

個人の保存メモリーは `/api/v1/user/memory`、Workspace の保存メモリーは `/api/v1/workspaces/{workspaceId}/memory` に置き、本文の `scope` で所有先を変更できないようにする。CRUD は各所有先の `/notes` と `/notes/{noteId}`、検索は `/recall` に置く。自動ルーティングは MCP／内蔵 Agent の共有サービスだけに公開する。Workspace の `DELETE /memory` は共有メモリーの全削除で、会議の正本は削除しない。

### 検索

`search_memories` と `/recall` は保存メモリーだけを対象にした、全文検索とベクトル検索の hybrid 検索である。`query` は質問文・文・キーワードのいずれでもよく（4,000 文字以内）、配置の analyzer で最大 16 語に分解する。Node と Lakebase は日本語を形態素解析し、助詞などの機能語を検索語にせず、どれかの語を含む記録を候補にする。Workers は単語分割だけで機能語を除けないため、全語を含む記録を語の候補にし、それが 1 件もなければどれかの語を含む記録に緩める。各 scope で語の一致（上位 100 chunk）と、embedding を設定した配置では意味の近さ（上位 100 chunk）を求め、記録ごとに最良の chunk にまとめてから RRF（k=60）で統合する。返すのは検索したすべての scope を合わせて最大 20 件である。

RRF の値は scope 内の順位だけから決まり、scope をまたいだ関連度の比較にはならない。そのため値の高い順に選び、同点は語の一致、次に scope の順（個人、続いて `list_memory_scopes` の順）で決める。全体の関連度順は約束しない。返した件数より多く該当した scope には `truncated: true` を付け、その scope だけを（必要なら `type` も付けて）検索し直せるようにする。意味検索ではベクトル候補に類似度の下限がなく、結果は絞り込みではなく順位である。そのため件数は返さない。結果が空でも、関連する会議がないことを意味しない。正本の行は返却直前に読み、返却前に scope の権限を再確認する。`type` を渡すと、語とベクトルの候補をその型の記録に限ってから順位を付ける。`instruction` で意味検索を使えたかを示す。`list_memories` の `query` は整理用途の文字どおりの部分一致である。

索引は正本から再構築できる chunk projection（[Memory と保存チャットの検索 projection](search.md#memory-と保存チャットの検索-projection2026-11-03)）に置き、正本の保存・更新と同じ transaction で書き換える。本文が変わらない chunk の vector は残す。embedding は非同期で、provider を待たない。現在の analyzer と正本 revision に一致する projection を持たない行は、正本を NFKC・小文字化した部分一致で語の検索に加える。

### 保存チャットの検索（Session store）

保存チャットの正本は Mastra 標準の `agent.mastra_threads` / `agent.mastra_messages` とし、Mastra の保存、Working Memory、Observational Memory、前後のメッセージ取得（`listMessages` の `include`）をそのまま使う。検索は Memory と同じ方式の chunk projection（`agent.session_search_chunks`）を run の終了後に job で作る。

内蔵 Agent だけが読み取り専用の `search_chat_history` を使える。対象は呼び出した本人の `dahlia-chat` thread のうち、現在のチャットの Workspace に属し、その Workspace を現在読めるものに限る。結果は該当メッセージ、その thread のタイトル、前後 1 件ずつのメッセージで、検証済みの事実ではない。索引が未作成の thread があるときは、語の検索が不完全であることを `instruction` で示す。Server MCP と Desktop のローカル MCP（`dahlia-mcp`）には公開しない。チャット本文を外部クライアントへ出す読み取り口は、別途の判断とする。

### 検索のための送信範囲（2026-11-03、ユーザー承認済み）

embedding を設定した配置（Databricks では Unity AI Gateway 経由の `system.ai.qwen3-embedding-0-6b`）では、次の本文を App service principal の権限で embedding endpoint へ送る。保存メモリーの本文（個人・共有）、`dahlia-chat` の user / assistant メッセージ本文、memory recall と `search_chat_history` の query 原文。会議検索の送信範囲（要約、OCR、caption、query）に加わる。送るのは 8,000 bytes 以内の chunk で、文書側に instruction は付けず、query には memory 用と chat 用の instruction を付ける。instruction と query の合計が 8,000 bytes を超える query は送らず、語の検索だけにする。Dahlia は返された vector だけを projection に保存し、query を保存・log しない。暗号化 Workspace はメモリーと保存チャットを扱わない（409）ため、送信対象にもならない。

運用者は、App service principal が embedding model を呼べる権限と、Gateway 側の usage tracking / payload logging（inference table）の設定を確認する。payload logging を有効にすると、送信した本文は Gateway 側に保存される。

公式資料に記載のない endpoint の挙動は、2026-11-03 に開発用 workspace でユーザー token と合成テキストだけを送って確かめた。`dimensions`（256 を指定すると 256 次元）と `instruction`（Qwen3 の `Instruct: …\nQuery:` 前置きとほぼ同じ vector、cosine 0.999）は効き、20 件の batch も受け付け、32,768 token を超える入力は 400 で拒否した（切り詰めない）。日本語の繰り返し文では 1 token がおよそ 2.3 bytes で、8,000 bytes の chunk は上限より十分小さい。この確認は開発用 workspace での一回限りの測定である。

### 外部の整理処理

メモリーの整理・統合（いわゆる dreaming）は Dahlia の内部に置かず、定期ジョブも作らない。利用者が設定した外部クライアント（例: `mcp:memory:write` を持つ Claude Code や Codex の定期タスク）が、通常の MCP 操作で行う。`list_memories` を `nextCursor` に沿って全件読み、統合したメモリーを新しい ID で保存してから、元のメモリーを現在の revision で削除する。競合時は読み直して判断し直す。人が編集したメモリーの書き換えと Workspace メモリーの整理は、利用者がその処理に明示的に任せた場合だけ `explicit: true` で行う。Dahlia は自らメモリーを剪定・統合しない。

外部クライアントの read/share は Codex の login scopes と Claude Code の `oauth.scopes` に反映し、変更時は再認証する。クライアント指示や任意の hooks はツール呼び出しのタイミングを決めるが、認可境界には使わない。Header/proxy 環境の権限はサーバー単位の管理者設定であり、クライアントごとに分離する場合は Accounts OAuth を使う。

## Hindsight の退役（2026-11-03）

Hindsight は使わない。保存メモリーの正本は当時から Dahlia の DB にあり、Hindsight の内容は正本から再構築できる派生データだった。

| 領域 | 現在の扱い |
| --- | --- |
| `app.personal_memories` / `app.shared_memories` | Memory store の正本。スキーマ・ID・revision・保護フラグは不変 |
| 取り込み状態の表（`jobs.workspace_memory_state`、`jobs.memory_source_jobs`、`jobs.memory_documents` と `personal_` 版）、Knowledge Pages の公開記録（`search.knowledge_pages`） | 宣言 schema にない |
| Hindsight bank（`hindsight` schema の事実・観察・mental model） | 使わない。Lakebase の `hindsight` schema は削除しない |
| `jobs.queue` の `workspace-memory` / `personal-memory` ジョブと `DAHLIA_JOB_LIMITS` の `memory` | 実行しない。残った行は取得対象外で、上限計算にも数えない。設定に残った `memory` キーは無視して起動を妨げない |
| recall | Dahlia の DB 内の projection による hybrid 検索（日本語 tokenizer の全文検索と embedding）。reranker と出典抜粋の検証は持たない。会議は対象外で、根拠は会議ツールで確認する |
| reflect（出典付き仮説）、Knowledge Pages、画像取り込み、分析の有効化・状態・再試行 | 廃止。仮説や要約は外部クライアントが必要に応じて作り、保存メモリーとして書き戻す |
| `DAHLIA_HINDSIGHT_*`、`DAHLIA_MEMORY_IMAGE_*`、Databricks の Hindsight App と `apps/hindsight` | 使わない。旧環境変数は無視する |

これは Hindsight の機能の同等移植ではない。会議からの自動学習、reflect、Knowledge Pages、画像取り込みは Dahlia 内に代替を持たない。意味検索は保存メモリーと保存チャットに限り、Dahlia の DB 内の projection として持つ（[検索](#検索)）。

Mastra の標準 Memory は thread と resource に紐づく会話の記憶（会話履歴、意味想起、Working Memory、Observational Memory）である。Mastra は tools、保存チャット、Working Memory で使い、保存メモリーの保存先には使わない（[却下した案](#却下した案)）。

## 移行と切り戻し

Server は未リリースである。2026-11-05 に application migration は initial と runtime_support の 2 本に統合され、退役表は新しい DB に作らない（[Schema と migration](database-and-identity.md#schema-と-migration)）。保存メモリーの `type` 列もこの統合に含む。旧 baseline を適用済みの DB は自動変換せず、新しい空の DB に作り直す。

旧 DB に残った退役表、`jobs.queue` の `workspace-memory` / `personal-memory` 行、Lakebase の `hindsight` schema は Dahlia が使わず、消しもしない。不要になった時点で運用者が明示的な承認を得て削除する。Hindsight を使う前のバージョンへの切り戻しは旧 DB で前のバージョンを動かすことに当たり、このバージョンの DB とは互換がない。

Databricks では、Hindsight App を宣言しない bundle で `bundle deploy` すると App が削除される。`databricks bundle plan` で確認し、運用者の承認を得て実施する。

## 却下した案

- 外部の記憶サービス（Hindsight）で保存メモリーを扱う: 運用面で、別の Databricks App、Python の上流パッチ管理、reranker、取り込み worker と多数の整合性検証が必要だった。
- Mastra の標準 Memory を保存メモリーの保存先にする: ID・revision・Workspace 共有・外部クライアントからの書き込みを持つ記録の保存先ではない。
- Mastra の semantic recall、PgVector、knowledge domain を検索層に採る: semantic recall と PgVector は dense vector だけで語の検索を持たず、PostgreSQL 専用である。knowledge domain は experimental で、PostgreSQL の語検索が LIKE である。
- 文から内容語を規則で推定して検索する: 助詞の混入や 1 文字名詞の欠落が起きる。辞書を持つ形態素解析器の採用で解消する。
- 検索のたびにモデルで保存先・検索先の scope を振り分ける Router: 検索のたびにモデルを呼ぶ遅延と結果の揺れが、「答える前に検索する」使い方に合わない。共有には `explicit` が必要なため、保存先の提案も実質的に個人か見送りだった。

## 未適合・未検証

- 未確定: 議事録から顧客の情報を整える機能の扱い。型ではなく顧客 Project との関連として別途判断するとあるが、判断は未了である。
- 未検証: App service principal の OAuth、429 の頻度、embedding endpoint の batch 上限、payload logging の有無は確認していない（[検索のための送信範囲](#検索のための送信範囲2026-11-03ユーザー承認済み)）。
- 未検証: 2026-11-03 の endpoint 測定は開発用 workspace での一回限りの確認である。
