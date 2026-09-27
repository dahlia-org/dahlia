# Dahlia Memory の個人領域と外部エージェント

状態: 採用。個人・Workspace のメモリー、Web 管理、MCP と Router を実装する承認済みプランに対応する。

## 決定

ユーザー向け名称を Dahlia Memory に統一する。保存メモリーの正本は Dahlia の DB、Hindsight は再構築可能な分析先とする。個人領域は認証済み user UUID、共有領域は現在アクセス可能な Workspace UUID に固定する。スレッド所有権、話題、共有先は独立した概念である。

個人領域を T4 の Workspace 境界への追加とする。会議データの Server MCP は従来どおり読み取り専用。メモリーだけは独立した `mcp:memory:read` / `mcp:memory:write` を設け、既存の `mcp` / `mcp:read` / `all-apis` を書き込み権限に昇格させない。信頼済み header 配置では運用者が `DAHLIA_MEMORY_MCP_ACCESS=read|write` を明示する（既定 off）。Desktop ローカル MCP の `--write` 契約は変えない。

一覧・取得・更新・削除は明示した scope を使う。新規保存と検索にだけ `auto` を認め、Router が個人／現在指定された Workspace／両方／不明を提案する。認可はモデルの前後と DB の操作時にサーバーが実施する。モデル出力は bank ID や閲覧者を決めない。モデル失敗時、検索は許可された候補を検索し、保存は見送る。個人と共有の混在も保存を見送る。

個人の簡潔な学習はエージェントが保存できる。共有、削除、ユーザー編集済みメモリーの変更は、利用者の明示的な指示を必要とする。`explicit` はその指示を伝えるクライアントの申告であり、自然言語の同意をサーバーが検証した証拠ではない。共有には現在の editor/admin 権限も必須。Web は内容と宛先を提示して確定する。私的な会話全体を自動取り込みせず、個人メモリーを共有へ自動移動・複製しない。

個人と Workspace は別 Hindsight bank とし、既存 Workspace bank 名を保持する。canonical revision と hash を再検証して更新・削除済みの出典を除外する。分析が停止・未設定でも正本の CRUD と本文検索は使える。Node の既存 worker、Workers の既存 queue と cron を両領域で再利用する。

## 移行と制限

Server は未リリースのため、個人領域の表と共有ノートの人手保護フラグを既存のメモリー migration に統合し、個人表の FORCE RLS も既存のメモリー RLS migration にまとめる。Drizzle snapshot と登録一覧を同期する。適用済みの開発 DB は自動更新されない。検証は新しい空 DB を使い、保持が必要な DB や migration ledger を削除・変更しない。個人表は owner RLS、SQLite は同じアプリケーション認可を使う。削除後の remote bank cleanup のため、本文を含まない job 状態はアカウント削除に追随して消さない。

汎用 Agent を外部公開せず、内蔵 Agent と MCP は同じ bounded tools を使う。個人の Working Memory は Mastra の resource-scoped Markdown とし、手動メモと明示的で継続的な利用者発言から学習したメモを分ける。Web・内蔵 Agent・MCP は同じ owner と revision を使う。`GET/PATCH /api/v1/user/memory/working` と `get_working_memory` / `update_working_memory` で本人に公開し、チャット削除では保存済みの内容を消さない。個人の保存済み記憶は `/api/v1/user/memory`、Workspace の保存済み記憶と長期記憶の管理は `/api/v1/workspaces/{workspaceId}/memory` に置き、本文の `scope` で所有先を変更できないようにする。保存メモの CRUD は各所有先の `/notes` と `/notes/{noteId}` に統一し、分析は `/analysis/status` と `/analysis/settings`、検索と考察は `/recall` と `/reflect` に置く。自動ルーティングは MCP／内蔵 Agent の共有サービスだけに公開する。Workspace の `DELETE /memory` は共有メモと Hindsight bank の全削除で、会議の正本は削除しない。スレッド Observational Memory と会議由来の live context は別領域とし、live context API は `/api/v1/chat/{threadId}/live-context` に置く。

外部クライアントは `mcp:memory:read` による参照専用と `mcp:memory:write` による記憶共有を選べる。クライアント指示や任意の hooks はツール呼び出しのタイミングを決めるが、認可境界には使わない。Header 配置の権限はサーバー単位の設定であり、クライアントごとに分離する場合は Accounts OAuth を使う。既存の全文会話を自動取り込みせず、長く使う個人の学びだけを簡潔に保存する。

Working Memory の編集中セクションは読込時の revision を維持し、別クライアントによる同セクションの更新を上書きしない。学習メモの上限到達時は既存内容を保持して自動学習を停止し、`capacityReached` と UI で通知する。利用者が整理・再有効化する。外部クライアントの read/share は Codex の login scopes と Claude Code の `oauth.scopes` に反映し、変更時は再認証する。Header/proxy 環境の権限は管理者設定であり、クライアント指示や hooks は権限を変更しない。

## Hindsight の版と評価

2026-09-26: 分析先を Hindsight 0.10.1（`f8950b0c`）に固定した。observation、directive、Knowledge Pages などの機能を段階的に使うための前提であり、この更新では Dahlia が送る retain、recall、reflect、mental model の要求の形を変えない。Lakebase 向けの保守パッチは、上流が名称変更を更新処理に統合した分だけ縮めた。0.10 系では、reflect の取得ツールが失敗すると reflect 全体が HTTP 500 になる。この場合は既存の `memory_upstream_failed` として、その scope を利用不可にし、正本の文字列一致による候補を返す。recall だけの結果に切り替えて仮説を省く縮退は採らない。

検索設定の比較は、運用者がローカルで実行する評価ハーネスで行う。対象の bank を Hindsight の clone で複製し、複製先だけで hit@k、MRR、応答時間を測り、終了時に複製先を削除する。質問と期待する文書の組は運用者が用意し、リポジトリに置かない。出力は数値だけで、質問、想起した文、本文は出さない。reranker の実装はサーバーの設定なので、実装どうしの比較はそれぞれの設定の App に対して行う。

## 検索の精度と系譜（Phase 1）

2026-09-27: recall の並べ替えに、Hindsight App の中で動かす cross-encoder を使う。モデルは多言語の `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` で、CPU に固定する。Model Serving に分けると、App の外に呼び出しと認証がもう一つ増えるため、分けない。App の compute は Large（4 vCPU）とする。4 CPU での計測では、並べ替えに 50 件で 0.64 秒、100 件で 1.25 秒、200 件で 2.2 秒、300 件で 3.4 秒かかり、RSS は約 1.4 GB だった。合成データで作った日本語 12 問では hit@1 が 1.00 だった。比較した flashrank の MultiBERT は、300 件で 10.7 秒、hit@1 は 0.33 だったので採らない。候補数の上限は recall の budget ごとに DAB 変数で持ち、既定は low 50、mid 100、high 300 とする。モデルの重みは起動時に Hugging Face から取得する。App が外部に出られない場合は、UC Volume に置いた重みを起動時にコピーする案があるが、今は実装しない。

reranker のために上流の `local-ml` extra を入れる。torch は、上流の `tool.uv.sources` によって PyTorch の CPU 専用 index から解決され、GPU 用の大きな wheel を入れない。uv 0.8 の `uv export` は index URL を出力しないので、Databricks Apps が pip で読む `requirements.txt` の先頭には CPU 専用 index を足す。その手順と `uv.lock` の一致は `scripts/check.sh` で確かめる。

証拠として返すのは、今までどおり hash を検証した正本の抜粋だけとする。長い会議では、recall で関係した事実の chunk から `[Transcript segment <id>` と `[Screenshot <id>` の ID だけを取り出し、正本の中のその段落と前後 1 段落を切り出す。chunk の本文、observation の本文、抽出された事実は返さない。chunk の取得 API は bank をパスに含まないため、応答の bank と文書が期待どおりのときだけ使う。16,000 文字に収まる文書は全文を返し、マーカーが見つからなければ冒頭を返す。observation は、元になった事実の文書をたどって候補にする。recall には `include.entities: null` を付け、人物の集約を Hindsight に求めない。

MCP と HTTP から、Project、期間、検索の深さを指定できる。Project は現在の Workspace に属するものだけを受け付け、正本での所属も確かめる。個人の領域では受け付けない。`auto` と一緒に指定されたときは、Router を使わずにその Workspace だけを検索する。期間は Hindsight の temporal window として、期間内を優先するだけで、期間外を除外しない。深さは recall の budget にだけ対応させ、reflect の budget は `low` のまま変えない。
