# Dahlia Memory の個人領域と外部エージェント

状態: 採用。個人・Workspace のメモリー、Web 管理、MCP と Router を実装する承認済みプランに対応する。

## 決定

ユーザー向け名称を Dahlia Memory に統一する。保存メモリーの正本は Dahlia の DB、Hindsight は再構築可能な分析先とする。個人領域は認証済み user UUID、共有領域は現在アクセス可能な Workspace UUID に固定する。スレッド所有権、話題、共有先は独立した概念である。

個人領域を T4 の Workspace 境界への追加とする。会議データの Server MCP は従来どおり読み取り専用。メモリーだけは独立した `mcp:memory:read` / `mcp:memory:write` を設け、既存の `mcp` / `mcp:read` / `all-apis` を書き込み権限に昇格させない。信頼済み header 配置では運用者が `DAHLIA_MEMORY_MCP_ACCESS=read|write` を明示する（既定 off）。Desktop ローカル MCP の `--write` 契約は変えない。

一覧・取得・更新・削除は明示した scope を使う。新規保存と検索にだけ `auto` を認め、Router が個人／現在指定された Workspace／両方／不明を提案する。認可はモデルの前後と DB の操作時にサーバーが実施する。モデル出力は bank ID や閲覧者を決めない。モデル失敗時、検索は許可された候補を検索し、保存は見送る。個人と共有の混在も保存を見送る。

個人の簡潔な学習はエージェントが保存できる。共有、削除、ユーザー編集済みメモリーの変更は、利用者の明示的な指示を必要とする。`explicit` はその指示を伝えるクライアントの申告であり、自然言語の同意をサーバーが検証した証拠ではない。共有には現在の editor/admin 権限も必須。Web は内容と宛先を提示して確定する。私的な会話全体を自動取り込みせず、個人メモリーを共有へ自動移動・複製しない。

個人と Workspace は別 Hindsight bank とする。bank／document の命名は後述の「識別子の統一」に従う。canonical revision と hash を再検証して更新・削除済みの出典を除外する。分析が停止・未設定でも正本の CRUD と本文検索は使える。Node の既存 worker、Workers の既存 queue と cron を両領域で再利用する。

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

reranker のために上流の `local-ml` extra を入れる。torch は、上流の `tool.uv.sources` によって PyTorch の CPU 専用 index から解決され、GPU 用の大きな wheel を入れない。uv 0.8 の `uv export` は index URL を出力しないので、Databricks Apps が pip で読む `requirements.txt` の先頭には torch 専用の `--find-links https://download.pytorch.org/whl/cpu/torch/` を足す。他の依存を PyTorch index から解決する `--extra-index-url` は使わない。その export 手順と `requirements.txt` の一致は `scripts/check.sh` で確かめる。

証拠として返すのは、今までどおり hash を検証した正本の抜粋だけとする。長い会議では、recall で関係した事実の chunk から `[Transcript segment <id>` と `[Screenshot <id>` の ID だけを取り出し、正本の生成時に保持したブロック位置から一致箇所を先に確保し、残りで前後の文脈を切り出す。OCR や transcript 内の空行では分割しない。追加の chunk 取得は全体で 3 秒、1 文書あたり 3 件までとし、失敗しても正本の再検証を続ける。chunk の本文、observation の本文、抽出された事実は返さない。chunk の取得 API は bank をパスに含まないため、応答の bank と文書が期待どおりのときだけ使う。16,000 文字に収まる文書は全文を返し、マーカーが見つからなければ冒頭を返す。observation の系譜に対応するが、実データでの品質・応答時間の評価までは recall の既定を world/experience にする。評価は出典を展開した文書に個別の順位を付け、5 文書で打ち切る。recall には `include.entities: null` を付け、人物の集約を Hindsight に求めない。

MCP と HTTP から、Project、期間、検索の深さを指定できる。Project は現在の Workspace に属するものだけを受け付け、正本での所属も確かめる。個人の領域では受け付けない。`auto` と一緒に指定されたときは、Router を使わずにその Workspace だけを検索する。期間は Hindsight の temporal window として、期間内を優先するだけで、期間外を除外しない。深さは recall の budget にだけ対応させ、reflect の budget は `low` のまま変えない。

期間付き reflect は、上流が temporal window を受け付けない間、recall の出典だけを返して仮説を生成しない。Project 指定は分析が未設定・失敗した場合も維持し、Project に属さない共有メモを fallback で返さない。期間の検証は分析の有無にかかわらず入口で行う。

T2 のため、worker は新規・既存 bank の free-form entity、entity labels、graph retrieval を無効にしてから読み取りを許可する。reflect と model refresh の observation entity 添付も無効にする。上流の内部 recall が entity 添付を強制する経路には、entity を使わない bank では過去の entity も返さない最小のパッチを置く。過去に保存済みの派生データは設定変更だけでは消えないため、削除には明示的な purge・正本からの再構築を使う。配備順は Hindsight App、Server とする。App のログは上流の JSON allowlist で severity・timestamp・logger だけを出し、Uvicorn にも同じ設定を適用する。

## 主張ごとの出典と処理設定（Phase 2）

reflect は上流の `response_schema` で主張と fact ID を取得する。構造化は回答文への追加 LLM 呼び出しであり、出典や内容の正しさを保証しない。Server は各 ID が同じ応答の `based_on.memories` に存在すること、同じ bank の有効な fact／observation の系譜を持つこと、現在の認可・Project 所属・正本 revision/hash に対応することを確かめる。主張ごとの全出典を返せない場合は主張全体を除外する。最大10主張・参照10 fact・observationあたり20元fact、候補30文書・返却5文書の上限を超える参照は検証済みにしない。fact の chunk は正本抜粋の位置の手がかりにのみ使い、引用本文には使わない。

結果の `claims[].citations` は fact ID と、その結果の `sources` への0始まりの `sourceIndexes` を持つ。互換用 `hypothesis` は採用した主張だけから組み立てる。構造化出力の欠落、処理エラー、不正形式、空の主張、参照不成立、一部除外、期間制約、取り込み更新中は `reflectionStatus` で区別し、上流の非構造化回答やエラー本文は公開しない。Web・内蔵AI・MCPは同じ結果を使う。系譜が正本に一致しても、主張の意味的な裏付けや真実性を証明したことにはならない。

対話reflectは `exclude_mental_models: true` とし、生成ページを独立した証拠にしない。既存の retain／observations／reflect mission を再利用し、独立directiveや利用者向け設定を追加しない。worker が `reflectionPolicy` を記録して新規・既存bankへ固定missionを適用し、適用前には読み取りを許可しない。dispositionは既定のままにする。比較時の変更は評価用bankの `/config` の `disposition_skepticism`、`disposition_literalism`、`disposition_empathy` を使い、`/profile` は使用しない。

処理別LLMは上流標準の RETAIN／REFLECT／CONSOLIDATION／MENTAL_MODEL_REFRESH 設定を使う。既定は `databricks`／`system.ai.gpt-6-luna`。refreshの追加構造化呼び出しも専用refresh設定を使う最小パッチを置く。期間付きreflectの仮説抑止、reflect budget `low`、全体30秒の期限、利用者キャンセルは維持する。`reflectionUsage` は上流が報告した構造化呼び出し込みのreflect token数だけで、recallやembeddingの費用を含む総額ではない。

rerankerの重みは `1427fd652930e4ba29e8149678df786c240d8825` に固定し、既存のHugging Face依存で取得したsnapshotを上流のローカルモデル設定に渡す。新しい依存やUC Volume経路は追加しない。過去entityや既存派生物は設定変更では削除しない。原文の人物名と構造化entityは別物であり、正本の人物名は保持する。必要な旧データの削除・正本からの再構築は別途明示的な許可を得て実施する。

## 標準 Knowledge Pages（Phase 3）

Workspace の `workspace-insights` と既存 Project の `project-{UUID}` をそのまま公開対象にする。別のページ用モデル、任意プロンプト、生成本文の編集機能は作らない。生成と更新は既存 worker と上流の full refresh / 自動更新が所有する。標準生成条件は Server の `standardModel` に集約し、既存モデルの trigger に残る任意設定も明示的に解除する。

Dahlia の `search.knowledge_pages`（SQLite は `knowledge_pages`）は再構築可能な公開記録である。本文、モデル fingerprint、生成条件と時刻、全正本の ID・revision/hash、全 fact の系譜を一体で保存する。Workspace の現在の権限を使い、PostgreSQL は FORCE RLS を適用する。Phase 3 では追加 migration とした。2026-09-28 のユーザー承認により、Server の未リリース baseline に統合した（[詳細](database-and-identity.md#リリース前-baseline-統合2026-09-092026-09-28更新)）。既存 DB と bank の変更は実行しない。

上流が既に検索の上限時刻として使う DB cutoff と実際の生成条件を `reflect_response.dahlia_generation` に保存し、fact detail に `updated_at` を添付する最小パッチを置く。生成後に変わった fact はマイクロ秒精度で拒否する。保守パッチ適用前のモデル、出典なし、途中の処理結果は公開しない。worker は generation・lease・再生成要求の版を照合し、古い cutoff の完了が新しい公開記録を上書きしないようにする。同じ本文でも正本 revision が変われば Workspace retain を送って系譜 metadata を更新する（上流の差分 retain を再利用）。

一覧・文字列検索・詳細・Markdown export・内蔵 AI・MCP は一つの公開判定を通る。型別 `based_on` の world/experience/observation を同じ bank の現在有効な fact から全正本まで辿り、全 observation source も検証する。モデル・directive・循環した系譜を証拠として受け付けない。対話検索の5文書返却・30候補制限を流用しない。30秒の期限、キャンセル、上流応答と詳細返却の2 MiB制限で全検証を完了できなければ公開しない。外部処理の後に現在の認可、正本、generation、全 fact、上流モデルと公開記録を再確認する。一覧では後続ページの検証完了後にも先行ページを含む全 fact を再確認し、失効した snippet を検索結果へ返さない。`is_stale` だけでは公開を許可しない。

公開状態は ready / generating / stale / source_invalid / paused / unavailable / error / no_sources、取り込み coverage は ready / partial / updating と分ける。非公開状態では生成本文・snippet・説明文・exportを出さない。検索結果には検証済みページだけを載せる。Web は本文を文字列で表示し、HTMLや外部画像を読み込まない。ページは独立した証拠ではなくAI要約・仮説であり、出典リンクは正本の確認・訂正へ戻る導線である。

再生成は Workspace 管理者の Web 操作のみで、要求を保存して直ちに返す。閲覧は生成を起動しない。MCP と内蔵 AI に公開するのは `list_knowledge_pages` と `get_knowledge_page` だけで、MCP は `mcp:memory:read` を使う。write scope があってもページの書き込み tool は存在しない。既存の正本メモ CRUD は維持する。

## Phase 4: 取り込み設定と品質

正本の `contentHash` は従来どおり本文の一致だけを表す。別の `ingestionFingerprint` に正本の revision/hash、文書組み立ての版、固定 mission、上流の有効な抽出設定・選択 strategy・処理別モデル・entity 方針を含める。資格情報を含む resolved config 全体は保存・公開しない。上流 `/config` の Dahlia adapter は明示した非機密設定から digest のみを付加する。原文や主張の真実性、独立した裏付けの数を保証する値ではない。

worker は既存 bank も `/config` で確認し、設定が変われば generation を進めて既存の再走査を使う。旧行の fingerprint 未設定は移行未完了とする。本文が変わった場合は retain、設定による再抽出は正本本文・metadata の同期後に標準 document reprocess を使う。同じ本文の retain は抽出を省くことがあるため、代用しない。段階、開始設定、operation ID は永続化する。reprocess の ID を既存の retain 冪等性に渡す最小パッチにより、応答喪失後も同じ operation を確認・再送する。

上流の各抽出 batch は開始時の期待設定と有効設定を照合する。完了時には現在の認可、正本 revision/hash、generation、設定、保存文書・metadata・抽出件数を確認する。抽出ゼロは `memory_no_facts`、Gateway 拒否は `memory_policy_blocked`、一時的な処理障害は有界再試行後に `memory_operation_failed` とする。拒否・抽出ゼロを ready や検索結果なしとして隠さず、coverage / skippedCount / skippedSources に反映する。決定的な失敗は自動で繰り返さず、正本・設定変更または管理者の既存「再試行」で再評価する。

recall / reflect と Knowledge Pages の本文・snippet・export は同じ現在設定と正本の境界を通す。設定移行中の旧結果は公開せず updating / generating / stale を返す。ページは全ての参照 fact の設定 stamp も確認する。会議の transcript、AI 要約、OCR、caption は同じ `meeting_id` の一つの証拠群で、fact の数を独立した裏付け数に換算しない。

秘密情報・PII の検出と伏せ字は Gateway の設定に委ねる。Dahlia 独自の regex / redact と上流 Memory Defense の有効化は追加しない。Memory Defense は秘密情報等の regex 検出であり、一般的なプロンプト注入防御とは別物である。Gateway を通らない Hindsight の正本文保存、Dahlia 正本抜粋、直接の MCP 出力が秘匿されるとは保証しない。正本と通常の正本閲覧は変更しない。Databricks の HTTP 200 に含まれる `databricks_service_policy` は provider 境界で恒久拒否に変換し、生成された回答として扱わず、自由文の拒否理由を保存・ログ・公開しない。

取り込み品質の比較は `apps/server/scripts/evaluate-memory-ingestion.ts` の運用者用ハーネスを使う。公開 API やモデル入力に評価 bank を選ぶ引数はない。本番で抽出ゼロ・拒否・未取り込みの文書も含む現在認可された正本を列挙し、標準 `/config` の設定だけを写した隔離 bank に取り込み、短命な取り込み記録を使って本番の `WorkspaceMemoryService.search` を実行する。bank clone は使わず、directive・webhook・本番の非同期 operation を複製・作成しない。本番の記録・正本は変更しない。concise / verbose / 明示指定した既存 strategy を比較し、終了時は今回作成した評価 bank だけを削除する。最終文書の hit@5 / MRR、抜粋内の必要証拠、引用欠落、期待・禁止主張、会議重複、partial / 拒否 / 抽出ゼロ / エラー、応答時間を集計する。主張の期待・禁止判定は入力文字列との包含比較で、意味的正しさの自動判定ではない。出力は集計のみ。質問・個別結果・本文は commit しない。今回は合成データでハーネスを検証し、実データ比較は未実施。既定の concise、strategy 未指定を維持する。

## 識別子の統一

Hindsight の bank は Server が認証済み user／現在認可された Workspace の内部 UUID から導出する。既存の `encodeId`／`decodeId` を再利用し、Workspace は `dahlia_${encodeId("workspace", workspaceUUID)}`、個人は `dahlia_${encodeId("user", userUUID)}` とする。固定の `dahlia_` は設定可能にしない。環境分離は専用の Hindsight App／接続先・認証・保存先が担い、`DAHLIA_HINDSIGHT_BANK_PREFIX` と `AppConfig.hindsight.bankPrefix` は廃止する。旧環境変数が残っていれば、空文字でも Node／Worker 共通の固定エラーで起動を拒否する。

会議 document は `encodeId("meeting", meetingUUID)`、個人・共有の保存メモ document は `encodeId("sharedMemory", noteUUID)` とする。個人と共有は bank で分離し、document にアプリケーション prefix を重ねない。要約更新でも同じ会議 document を更新する。文書の種類・復号した UUID と保存記録・現在の正本の対応を確認し、形式や prefix だけで認可しない。画像 manifest の documentId も同じ ID を使う。

内部 UUID、`workspace-insights`／`project-{Project UUID}`、`project:{Project UUID}`、metadata の source_kind／source_id／source_revision、画像の内部 UUID と公開 att_／file_ は維持する。上流 fact／chunk／attachment の ID と hash、および operation／transaction／generation／revision／lease の意味は変更しない。ID 統一のために正本文を変更せず、取り込み契約の版は ingestion policy／fingerprint に含める。

既存データがないことを前提とし、データ移行・二重読み書き・移行専用の状態管理は追加しない。評価用 bank は運用者専用ハーネス内の `dahlia_eval_<run UUID>` とし、製品設定や公開 API に bank を選ぶ入口を追加しない。ハーネスは同名 bank の不存在を確認し、今回作成した評価用 bank のみを削除する。
