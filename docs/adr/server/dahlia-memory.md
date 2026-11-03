# Dahlia Memory の個人領域と外部エージェント

状態: 採用。2026-11-03 に Hindsight を廃止し、Dahlia の DB を唯一の Memory store とした。

## 決定

ユーザー向け名称を Dahlia Memory に統一する。永続メモリーの正本は Dahlia の DB の保存メモリー（個人は `app.personal_memories`、共有は `app.shared_memories`）とし、外部の分析・記憶サービスを使わない。個人領域は認証済み user UUID、共有領域は現在アクセス可能な Workspace UUID に固定する。スレッド所有権、話題、共有先は独立した概念である。

保存メモリーは安定した `smem_` UUIDv7 TypeID、本文（16,000 文字以内）、正の `revision`、`updatedAt`、作成者、`protected`（Web で人が編集した印）を持つ。作成順は UUIDv7 が保持する。更新と削除は revision を照合し、一致しなければ `memory_revision_conflict` で拒否する。後勝ちで上書きしない。

会議の正本とメモリーは別物である。会議・要約・文字起こし・画像は既存の会議ツールと検索で扱い、メモリーへ自動で取り込まない。

### 権限と書き込み

個人領域は T4 の Workspace 境界への追加である。会議データの Server MCP は従来どおり読み取り専用とする。メモリーだけは独立した `mcp:memory:read` / `mcp:memory:write` を設け、既存の `mcp` / `mcp:read` / `all-apis` を書き込み権限に昇格させない。信頼済み header 配置では運用者が `DAHLIA_MEMORY_MCP_ACCESS=read|write` を明示する（既定 off）。Desktop ローカル MCP の `--write` 契約は変えない。

一覧・取得・更新・削除は明示した scope を使う。新規保存と検索にだけ `auto` を認め、Router（`DAHLIA_CHAT_MEMORY_MODEL`）が個人／現在指定された Workspace／両方／不明を提案する。認可はモデルの前後と DB の操作時にサーバーが実施し、モデル出力は保存先や閲覧者を決めない。モデル失敗時、検索は許可された候補を検索し、保存は見送る。個人と共有の混在も保存を見送る。

個人の簡潔な学習はエージェントが保存できる。共有、削除、人が編集したメモリーの変更は、利用者の明示的な指示を必要とする。`explicit` はその指示を伝えるクライアントの申告であり、自然言語の同意をサーバーが検証した証拠ではない。共有には現在の editor/admin 権限も必須。Web は内容と宛先を提示して確定する。私的な会話全体を自動取り込みせず、個人メモリーを共有へ自動で移動・複製しない。

### 共通の service と Mastra tools

`DahliaMemory` service がスコープ解決・認可・保存・検索を持ち、Web API、内蔵 Agent、MCP は同じ service method を通る。内蔵 Agent と MCP は同じ Mastra tools（`list_memory_scopes`、`list_memories`、`get_memory`、`recall_memory`、`save_memory`、`delete_memory`、`get_working_memory`、`update_working_memory`）を使い、MCP には `mcp:memory:read` で読み取り、`mcp:memory:write` で書き込みを公開する。汎用 Agent は外部公開しない。

個人の Working Memory は Mastra の resource-scoped Markdown とし、手動メモと明示的で継続的な利用者発言から学習したメモを分ける。`GET/PATCH /api/v1/user/memory/working` と `get_working_memory` / `update_working_memory` で本人に公開し、チャット削除では保存済みの内容を消さない。スレッド Observational Memory と会議由来の live context は別領域とし、live context API は `/api/v1/chat/{threadId}/live-context` に置く。Working Memory の編集中セクションは読込時の revision を維持し、別クライアントによる同セクションの更新を上書きしない。学習メモの上限到達時は既存内容を保持して自動学習を停止し、`capacityReached` と UI で通知する。

個人の保存メモリーは `/api/v1/user/memory`、Workspace の保存メモリーは `/api/v1/workspaces/{workspaceId}/memory` に置き、本文の `scope` で所有先を変更できないようにする。CRUD は各所有先の `/notes` と `/notes/{noteId}`、検索は `/recall` に置く。自動ルーティングは MCP／内蔵 Agent の共有サービスだけに公開する。Workspace の `DELETE /memory` は共有メモリーの全削除で、会議の正本は削除しない。

### 検索

`recall_memory` と `/recall` は保存メモリーだけを対象にしたキーワード検索である。`query` は呼び出し側が選ぶ空白区切りのキーワードで、文として解析しない。キーワードを NFKC と小文字化で正規化し（全角英字・半角カナ・大文字小文字を同一視する）、重複を除いて最大 16 個使う。各 scope の全メモリーを同じ正規化で部分一致させ、含むキーワードの数、次に `updatedAt` の順に並べて最大 20 件返す。文から内容語を推定する方式（文字数・文字種の規則、出現頻度による重み付け）は、助詞の混入や 1 文字の名詞の欠落を規則ごとに別の形で生んだため採らない。文のまま渡すと一致しにくいので、ツール説明、内蔵 Agent の指示、Web の入力欄でキーワード入力を求める。SQL の `lower()` は NFKC を適用できず、SQLite は ASCII しか小文字化しないため、照合は DB ではなくアプリケーションで行う。意味検索ではないため、結果が空でも関連する会議がないことを意味しない。保存メモリー数がキーワード検索の限界を超えたら、ベクトル索引の追加を検討する。

### 外部の整理処理

メモリーの整理・統合（いわゆる dreaming）は Dahlia の内部に置かず、定期ジョブも作らない。利用者が設定した外部クライアント（例: `mcp:memory:write` を持つ Claude Code や Codex の定期タスク）が、通常の MCP 操作で行う。`list_memories` を `nextCursor` に沿って全件読み、統合したメモリーを新しい ID で保存してから、元のメモリーを現在の revision で削除する。競合時は読み直して判断し直す。人が編集したメモリーの書き換えと Workspace メモリーの整理は、利用者がその処理に明示的に任せた場合だけ `explicit: true` で行う。Dahlia は自らメモリーを剪定・統合しない。

外部クライアントの read/share は Codex の login scopes と Claude Code の `oauth.scopes` に反映し、変更時は再認証する。クライアント指示や任意の hooks はツール呼び出しのタイミングを決めるが、認可境界には使わない。Header/proxy 環境の権限はサーバー単位の管理者設定であり、クライアントごとに分離する場合は Accounts OAuth を使う。

## Hindsight 廃止の対応と理由（2026-11-03）

2026-09 から 2026-10 にかけて、保存メモリーと会議を Hindsight の bank に取り込み、recall・reflect・Knowledge Pages・画像取り込みを提供していた。保存メモリーの正本は当時から Dahlia の DB にあり、Hindsight の内容は正本から再構築できる派生データだった。運用面では、別の Databricks App、Python の上流パッチ管理、reranker、取り込み worker と多数の整合性検証が必要だった。整理・統合を外部で持つ方針にしたため、これを廃止して構成を簡素にする。

| 現行（Hindsight） | 移行後 |
| --- | --- |
| `app.personal_memories` / `app.shared_memories`（正本） | そのまま Memory store として使う。スキーマ・ID・revision・保護フラグは不変 |
| `jobs.workspace_memory_state`、`jobs.memory_source_jobs`、`jobs.memory_documents` と `personal_` 版（取り込み状態） | 使わない。既存 DB の表は切り戻し用に残し、宣言 schema に退役表として保持する |
| `search.knowledge_pages`（Knowledge Pages の公開記録） | 使わない。既存 DB の表は同様に残す |
| Hindsight bank（`hindsight` schema の事実・観察・mental model） | 使わない。Lakebase の `hindsight` schema は削除しない |
| `jobs.queue` の `workspace-memory` / `personal-memory` ジョブと `DAHLIA_JOB_LIMITS` の `memory` | 実行しない。残った行は取得対象外で、上限計算にも数えない。設定に残った `memory` キーは無視して起動を妨げない |
| recall（意味検索・reranker・出典抜粋の検証） | 意味検索は廃止し、保存メモリーの NFKC 正規化したキーワード検索に置き換える。会議は対象外で、根拠は会議ツールで確認する |
| reflect（出典付き仮説）、Knowledge Pages、画像取り込み、分析の有効化・状態・再試行 | 廃止。仮説や要約は外部クライアントが必要に応じて作り、保存メモリーとして書き戻す |
| `DAHLIA_HINDSIGHT_*`、`DAHLIA_MEMORY_IMAGE_*`、Databricks の Hindsight App と `apps/hindsight` | 削除。旧環境変数は無視する |

これは Hindsight の機能の同等移植ではない。意味検索、会議からの自動学習、reflect、Knowledge Pages、画像取り込みは廃止であり、Dahlia 内に代替を持たない。

Mastra の標準 Memory は thread と resource に紐づく会話の記憶（会話履歴、意味想起、Working Memory、Observational Memory）である。ID・revision・Workspace 共有・外部クライアントからの書き込みを持つ記録の保存先ではない。そのため Memory store は既存の DB の表とし、Mastra は tools と Working Memory で使う。Mastra の semantic recall や PgVector は PostgreSQL 専用で、別の埋め込み索引の取り込みを必要とするため、今回は採らない。

## 移行と切り戻し

保存メモリーの表と行は変更しないため、データ変換はない。migration と Drizzle snapshot は変更せず、新しい DB にも退役表は作成される。退役表と `hindsight` schema は動作に使わないが、切り替え時点までの会議と保存メモリーから抽出した内容（事実、観察、Knowledge Pages の本文）を保持している。切り替え後の削除（会議、保存メモリー、Workspace、ユーザー、Workspace メモリーの全削除）はこれらに伝わらないため、削除済みの内容の派生コピーが残り続ける。例外は `search.knowledge_pages` で、Workspace の物理削除に合わせて外部キーで消える。保持期間は運用者が決め、切り戻しが不要になったら削除する。Hindsight を Databricks 以外（`DAHLIA_HINDSIGHT_URL` の別サービス）で運用していた場合、その bank も同様に運用者が削除する。

Databricks では、このバージョンの `bundle deploy` が Hindsight App を削除する計画になる。`databricks bundle plan` で確認し、運用者の承認を得て実施する。切り戻しは前のバージョンを再デプロイする。保存メモリーはそのまま使える。ただし廃止中の変更と削除は旧 worker に伝わっていないため、以前の分析状態から再開してはならない。再開すると、廃止中に削除した会議・メモリー・Workspace・ユーザーの内容が recall、reflect、Knowledge Pages に再び現れうる。前のバージョンは再デプロイした時点で worker が退役表の状態と `jobs.queue` に残った `workspace-memory` / `personal-memory` 行から処理を再開するため、どの配置（Databricks、Node、Workers）でも、前のバージョンを再デプロイする前に `hindsight` schema（または外部の Hindsight）の bank、退役表の行、それらのジョブ行を削除する（明示的な承認が必要）。SQLite では schema 名がなく、queue は `jobs_queue`、退役表は `workspace_memory_state` などの同名の表である。そのうえで再デプロイし、各 scope の分析を有効化し直して正本から作り直す。

退役表、残ったジョブ行、`hindsight` schema の削除は不可逆なので別の操作とし、明示的な承認を得て、切り戻しが不要になってから行う。表の削除は Drizzle schema から退役表を外して生成した forward migration で行い、`hindsight` schema は Lakebase で運用者が削除する。

検証: 保存・取得・更新・revision 競合・検索・削除・統合（新規保存と元の削除）を MCP 経由で確認するテスト、SQLite の再接続後の永続性、PostgreSQL の FORCE RLS と全削除の直列化、退役 kind のジョブ行が残った queue での取得を、それぞれ使い捨ての DB で確かめる。
