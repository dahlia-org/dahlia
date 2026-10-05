# Hindsight + Lakebase

Hindsight API の固定版に、`lakebase_text` / `lakebase_vector` バックエンドを追加した独立サービスです。
Python 3.11–3.14、Git、uv を使用します。Dahlia のアプリケーション連携は含みません。

## Databricks Apps への配備

`deploy/databricks` の DAB は Hindsight を Dahlia Server と別の Databricks App として配備します。Lakebase project と `databricks-postgres` database は共有し、Hindsight のテーブルと migration ledger は既定の `hindsight` PostgreSQL schema に分離します。

App 起動時に Databricks が注入する `PG*` 変数と `LAKEBASE_ENDPOINT` から接続を作り、共有拡張 `vector`、`pg_trgm`、`lakebase_text`、`lakebase_vector` が `public` にあることを advisory lock 下で確認してから migration を実行します。Lakebase の短命 credential は `/api/2.0/postgres/credentials` から App service principal で取得し、asyncpg の新規接続ごとに自動更新します。別 schema に既存拡張がある場合はデータを破壊せず起動を停止します。`databricks` providerはApp service principalのclient credentialsでOAuth tokenを更新し、AI Gatewayの`system.ai.gpt-6-luna`と`system.ai.qwen3-embedding-0-6b`をOpenAI互換APIで使用します。ユーザーのOBO tokenとDatabricks secretは使用しません。詳細は [`deploy/databricks/README.md`](../../deploy/databricks/README.md) を参照してください。

## 起動

```sh
cd apps/hindsight
uv run --no-project scripts/sync_upstream.py
uv sync --locked
cp .env.example .env
# .env に DB 接続とモデルプロバイダーの設定を記入する
uv run --locked hindsight-api --host 127.0.0.1 --port 8888
```

Lakebase Search をプロジェクトで有効化してください。DB は **DDL を実行できるプライマリ接続**を指定します。
初回起動で Hindsight のスキーマと検索拡張を作成します。アプリのDBロールに拡張作成権限がない場合は、管理者が事前に実行します。

```sql
CREATE EXTENSION IF NOT EXISTS lakebase_text WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS lakebase_vector WITH SCHEMA public CASCADE;
```

拡張と依存する `vector` は `public` に配置してください。Lakebase が利用できない場合に通常 PostgreSQL へ自動切り替えはしません。
短命のDBパスワードを使う場合、その更新は呼び出し側で管理してください。Databricks Apps 配備では Lakebase credential と `databricks` model provider の OAuth token を App service principal から自動更新します。

`hindsight-api`、`hindsight-worker`、`hindsight-admin` は取り込んだ本体のエントリーポイントです。
分離 worker の構成は upstream の環境変数を使い、API と worker に同じ検索・トークナイザー設定を渡します。
embedding は外部プロバイダーを使います。reranker だけは、上流の `local-ml` extra（sentence-transformers と PyTorch）を入れ、
App の中で cross-encoder を CPU で動かします。Databricks Apps では `local` と
`cross-encoder/mmarco-mMiniLMv2-L12-H384-v1`（多言語、日本語を含む）を使います。
モデルの重み（約 470 MB）は、`MemoryEngine.initialize` の起動時に Hugging Face から取得します。
`.env.example` はローカル開発向けで、モデルを取得しない `rrf`（検索結果の融合順位をそのまま使う）にしています。
Hindsight に `none` という reranker はなく、指定すると起動時にエラーになります。
`local-ml` extra は、使わない flashrank と、darwin arm64 だけの mlx も引き込みます。
HTTP API・認証設定は [upstream のドキュメント](https://hindsight.vectorize.io/)を参照してください。

App から Hugging Face に出られない環境では、起動が止まります。その場合は、事前に取得した重みを UC Volume に置き、
起動時に App のローカルディスクへコピーしてから、そのパスを `HINDSIGHT_API_RERANKER_LOCAL_MODEL` に渡す方法を取ります（未実装）。

`pyproject.toml` で公開 PyPI を既定のレジストリに指定しています。torch だけは、上流の `tool.uv.sources` によって
PyTorch の CPU 専用 index（`https://download.pytorch.org/whl/cpu`）から解決します。`uv.lock` には、linux の `2.14.0+cpu` と
darwin の `2.14.0` が入ります。固定済みのバージョンと配布ファイルのハッシュは維持しています。

Databricks Apps は `requirements.txt` から pip で入れます。uv 0.8 の `uv export` は index URL を出力しないため、
先頭に torch だけの wheel 一覧を `--find-links` で足して作ります。`--extra-index-url` は Jinja2 や MarkupSafe まで PyTorch 側から解決するため使いません。
この export はバージョンを固定しますが、pip での配布ファイルのハッシュ検証は行いません。`uv.lock` を変えたら、次のコマンドで作り直します。
`scripts/check.sh` は、同じ手順の出力と `requirements.txt` が一致することを確かめます。

```sh
{ echo "--find-links https://download.pytorch.org/whl/cpu/torch/"; uv export --locked --no-dev --no-hashes --quiet; } > requirements.txt
```

Databricks Apps は `python -m hindsight_lakebase.server` 経由で起動します。Hindsight と Uvicorn のログは
上流の JSON allowlist を使い、`severity`、`timestamp`、`logger` だけを出力します。本文・質問・回答・例外本文・tenant は出力しません。
HTTP access log も無効です。ローカルで `hindsight-api` を直接起動する場合には、この制限は適用されません。

## バックエンドの選択

| 環境変数 | 追加した値 | 処理 |
| --- | --- | --- |
| `HINDSIGHT_API_TEXT_SEARCH_EXTENSION` | `lakebase_text` | `tsvector` + `lakebase_bm25`、BM25関連度 |
| `HINDSIGHT_API_VECTOR_EXTENSION` | `lakebase_vector` | `vector` + `lakebase_ann`、cosine距離 |
| `HINDSIGHT_API_LLM_PROVIDER` | `databricks` | App service principalでAI GatewayのOpenAI互換`chat/completions`を呼び出す |
| `HINDSIGHT_API_{処理}_LLM_PROVIDER` | `databricks-responses` | 同じ認証・既定URLでAI Gatewayの`responses`を呼び出す（上流 `openai-responses` 実装） |
| `HINDSIGHT_API_EMBEDDINGS_PROVIDER` | `databricks` | 同じ認証でAI GatewayのOpenAI互換`embeddings`を呼び出す |
| `LAKEBASE_ENDPOINT` | Databricks Apps resource binding | 設定時にApp service principalの短命DB credentialへ自動で切り替える |

独立して指定できます。未指定時は upstream の `native` / `pgvector` のままです。
既存のバックエンドも維持しています。Lakebase は PostgreSQL バックエンドでのみ利用できます。
`databricks` / `databricks-responses` provider の既定 URL は `${DATABRICKS_HOST}/ai-gateway/mlflow/v1` です。同じ workspace origin の別経路は
upstream 標準の `HINDSIGHT_API_LLM_BASE_URL` と `HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL` で個別に上書きできます。
外部の OpenAI 互換 URL には App service principal token を送らず、upstream の `openai` provider と API key を使用してください。

全文検索は memory の `text + context + text_signals`、Knowledge Pages の `name + content` を対象にします。
通常登録、観察の生成・統合・更新、編集・復元、インポート、ページの更新・名称変更・内容クリアに同じ処理を適用します。
原文・embedding 入力は変更せず、原文と検索ベクトルを同じトランザクションで保存します。
トークナイザーの例外は書き込みをロールバックします。

BM25 索引は初回検索では作りません。[Lakebase の仕様](https://docs.databricks.com/aws/en/oltp/projects/lakebase-text)に従い、
**各テーブルへ初期データを登録した後、全文検索を使う前に**、対象スキーマで次のSQLを一度実行します。
空のテーブルの索引作成は、そこへ初めて登録するまで保留してください。スキーマ名は実際の設定に合わせます。
索引がない状態でそのテーブルを全文検索するとDBエラーになります。

```sql
CREATE INDEX idx_memory_units_text_search
  ON hindsight.memory_units USING lakebase_bm25 (search_vector);
CREATE INDEX idx_mental_models_text_search
  ON hindsight.mental_models USING lakebase_bm25 (search_vector);
```

BM25 の距離を昇順に評価し、上位層には正の関連度として返します。ゼロ一致は除外します。
bank・tenant・タグ・日時・スコア閾値の条件は既存SQL内に保持し、RRF と reranking は変更していません。
候補上限と prefilter は検索トランザクション内で設定します。`lakebase_vector` は既存の bank ごとの索引管理と
距離SQLを再利用します。`probes` / `epsilon` は Lakebase の既定値に任せ、HNSW 固有の設定を送信しません。

## 日本語トークナイザー

既定は SudachiPy + core 辞書、分割モード B、正規化形です。空白と記号を除き、助詞などは残します。
検索文と登録文に同じ処理を適用し、PostgreSQL 側は `simple` 設定を使用します。
`日本語検索` を `日本語 検索` に分割するため、`検索` という問い合わせでも照合できます。
分割単位や正規化で結果が変わるので、用途の日本語コーパスで比較してください。

処理を変える場合は、インポート可能な Python 関数を指定します。

```python
# src/hindsight_lakebase/custom_tokenizer.py
# 契約: tokenize(text: str) -> list[str]
def tokenize(text: str) -> list[str]:
    from hindsight_lakebase.tokenizer import sudachi
    return sudachi(text)
```

```dotenv
HINDSIGHT_API_LAKEBASE_TEXT_TOKENIZER=hindsight_lakebase.custom_tokenizer:tokenize
```

環境変数は管理者設定です。リクエストごとの関数指定は受け付けません。NUL文字や非文字列を含む結果はエラーにします。
無加工との比較には `hindsight_lakebase.tokenizer:identity` を使います。この場合も PostgreSQL の標準パーサーは通ります。
既存データのバックエンド切り替え、トークナイザー変更後の再処理は対象外です。
バックフィル、再構築CLI、変更検知はありません。新しいDBで使用するトークナイザーを最初に選び、
API と worker で同じ設定を使用してください。以降の保存・編集・統合・インポートで検索用データを更新します。

## upstream の取得と更新

```text
apps/hindsight/
├── UPSTREAM.json                 # リリースバージョンと解決済みコミット
├── patches/hindsight-api-slim.patch # コア変更の正本
├── src/hindsight_lakebase/        # Lakebase拡張の正本
├── pyproject.toml / uv.lock       # uvのローカル依存・依存解決結果
├── scripts/sync_upstream.py      # 固定版の再生成／バージョン更新
├── scripts/check.sh              # 拡張とupstreamの回帰検証
├── tests/
└── .upstream/                    # 生成物。upstream全体のGitチェックアウト（Git管理外）
```

本体のコピーと個別ファイルのハッシュ一覧をDahliaのGitへ登録しません。
本体・ライセンス・全テストは、元のディレクトリ構成のまま取得します。
[uvのローカル依存](https://docs.astral.sh/uv/concepts/projects/dependencies/#path)で
`.upstream/hindsight-api-slim` を editable として参照します。
GitHubへ専用forkを公開する必要はありません。通常の起動ではパッチ適用や実行時の差し替えは行いません。

- `UPSTREAM.json`: 人が指定する `version` と、タグから解決した正確な `revision` を保持します。
- `uv.lock`: Python依存パッケージを固定します。ローカル依存のGitリビジョンは保持しないため、上記と併せて管理します。
- 引数なしの同期では固定済みコミットを再取得し、タグや最新版を追い直しません。
- 新規取得時は別ディレクトリでパッチ適用と `uv lock --check` を確認してから配置します。
- `--version` での更新時だけタグを解決し、`uv add --no-sync "hindsight-api-slim[local-ml]==X.Y.Z"` で依存指定と lockfile を更新します。
  成功後にソース・固定情報・`pyproject.toml`・lockfileを切り替えます。前のチェックアウトは `.upstream-backup-*` に残します。
- パッチ競合・依存解決失敗では現行のソース・固定情報・`pyproject.toml`・lockfileを変更しません。
  作業用チェックアウトに未保存の変更や未追跡ファイルがある場合も停止します。

現在の基準は正式リリース **v0.10.2**、コミット
`5fc4ce20917b916240cef27c212c387a177f115b` です。
`pyproject.toml` の `hindsight-api-slim[local-ml]==0.10.2` と `uv.lock` で依存を固定しています。

### バージョンを更新する

```sh
# X.Y.Z を対象の正式リリースに置き換える
uv run --no-project scripts/sync_upstream.py --version X.Y.Z
uv sync --locked
# requirements.txt を上の手順で作り直す
./scripts/check.sh
```

パッチ競合は自動で解決しません。対象版の保存・編集・統合・インポートの経路を確認し、
パッチを対応させてから同じ更新コマンドを再実行します。特に、新しい本文更新経路が増えていないかを確認します。
成功後は `UPSTREAM.json`、必要なパッチ・テスト変更、`pyproject.toml`、`uv.lock` をまとめてレビューします。

既存のローカルGitリポジトリからネットワークなしで取得する場合:

```sh
uv run --no-project scripts/sync_upstream.py --source /path/to/hindsight
```

コア修正を編集する場合は `.upstream` で試し、パッチへ書き出します。
未追跡の新規ファイルは別途パッチへ含める必要があります。前の作業ディレクトリを残して再生成し、検証してください。

```sh
git -C .upstream diff --relative=hindsight-api-slim HEAD -- hindsight-api-slim > patches/hindsight-api-slim.patch
mv .upstream .upstream-backup-edits
uv run --no-project scripts/sync_upstream.py
uv sync --locked
./scripts/check.sh
```

## コアへの接続

既存の Alembic revision は変更していません。履歴の実行だけを子プロセスへ分け、Lakebase に相当する設定を
その子プロセス内で `native` / `pgvector` に対応させます。その後、通常の初期化経路から追加の Lakebase 移行を実行します。
親プロセス・worker の設定は Lakebase のままです。日本語処理は `hindsight_lakebase` 内に限定します。

残したコア変更と理由:

| ファイル | 必要な理由 |
| --- | --- |
| `engine/provider_auth.py` | `databricks` / `databricks-responses` を API key 不要の provider として登録 |
| `engine/llm_wrapper.py` | `databricks` を OpenAI 互換 provider、`databricks-responses` を Responses provider として既存ディスパッチへ登録 |
| `engine/providers/openai_compatible_llm.py` | App service principal の短命 OAuth token を各 LLM リクエストへ供給し、AI Gateway の policy block を固定エラーにする |
| `engine/providers/openai_responses_llm.py` | `databricks-responses` で同じ OAuth token・AI Gateway URL・policy block 判定を使う |
| `engine/embeddings.py` | 同じ認証と AI Gateway URL を使う `databricks` embedding provider を登録。token は AsyncOpenAI が各リクエストの前に取得 |
| `engine/vector_index_health.py` | 既存の索引健全性チェックが lakebase_ann を認識するための登録 |
| `config.py` | 全文検索の選択値追加と PostgreSQL 以外での誤設定拒否。upstream の最小スコア契約テストも Lakebase の BM25 を検証する |
| `_vector_index.py` | 拡張名・ANN索引句・検索設定を既存ディスパッチへ登録 |
| `migrations.py` | 未変更の履歴を互換設定で実行し、選択された全文検索だけ初期設定。ANN型の識別（`lakebase_ann` の索引も検出）、次元変更時の bank 別索引管理の維持、mental_models の既存索引の対応 |
| `engine/sql/postgresql.py` | Lakebase BM25 SQL とクエリ処理への分岐 |
| `engine/search/retrieval.py` | BM25 の候補上限・prefilter を検索トランザクション内に限定 |
| `engine/db/ops_postgresql.py` | 通常保存・インポートが使う共通バッチ保存で本文と検索用データを同時更新 |
| `engine/memories/pg/writes.py` | 編集・復元の直接SQL後、既存トランザクション内で更新 |
| `engine/consolidation/consolidator.py` | 観察の新規作成・更新・重複統合の直接SQL後、既存トランザクション内で更新 |
| `engine/memory_engine.py` | ページ作成・更新・内容クリアの直接SQLで同時更新し、ページ検索にもBM25設定を適用。名称変更は upstream が更新処理を再利用する |
| `engine/transfer/importer.py` | 共通 `_restore_rows` の一箇所でページの本文保存と検索用データを同時更新 |

他バックエンドでは追加のDB処理・トークナイズ・Lakebase初期設定を実行しません。
既存のトランザクションがある保存経路では、それをそのまま利用します。

## 検索品質の評価

`scripts/evaluate_memory.py` は、運用者がローカルから実行する評価ハーネスです。
指定した bank を `POST /banks/{id}/clone` で複製し、複製先だけで recall を測ります。元の bank は変更しません。
終了時に複製先を削除します（`--keep-clone` を付けたときは残します）。
Dahlia の bank ID は `dahlia_ws_<26文字のTypeID suffix>` または `dahlia_user_<26文字のTypeID suffix>` です。固定の `dahlia_` は設定可能にせず、環境は接続先・認証・保存先で分離します。評価用 bank は各実行で生成する `dahlia_eval_<run UUID>` で、作成前に同名 bank が存在しないことを確認し、今回作成したものだけを削除します。

質問と期待する文書 ID の組は JSONL で渡します。リポジトリには置かないでください（`eval/` と `*.eval.jsonl` は Git の管理外です）。
文書 ID は Dahlia の公開 TypeID と同じ `mtg_<26文字のID>` または `smem_<26文字のID>` です。bank 内の ID に `dahlia_` は重ねません。

```jsonl
{"query": "...", "expected": ["mtg_01k45b0000e008000000000001"]}
```

```sh
export HINDSIGHT_EVAL_TOKEN="$(databricks auth token -p <profile> | jq -r .access_token)"
uv run --locked python scripts/evaluate_memory.py \
  --url https://<hindsight-app-url>/api --bank <bank ID> --questions ~/memory.eval.jsonl
```

- 出力は JSON の数値だけです。質問数と、組み合わせごとの hit@k（`--k`、既定は 1,3,5）、MRR、recall の応答時間（クライアントで計測した p50、p95、max のミリ秒）、エラー数を出します。質問、想起した文、本文は出力しません。
- 基準の recall は `types: world, experience`、`budget: mid`、`max_tokens: 4096` です。
  `--observations on|both` で observation を加え（`prefer_observations` を指定し、`source_facts` から元の文書に展開します）、
  Dahlia Server の既定（depth `normal`）は `--observations off` に当たります。常時利用は実データで品質と応答時間を比較してから判断します。
  `--rerank on|off|both` で複製先の `enable_reranking` を切り替えます。
  reranker の実装（`HINDSIGHT_API_RERANKER_PROVIDER`）はサーバーの設定なので、実装どうしを比べるときは、それぞれの設定の App に対して実行します。
- 順位は observation の出典を展開した後の、重複を除いた文書の順番です。Server と同じ 5 文書の枠で採点し、同じ observation の全出典を同順位にはしません。このハーネスは候補の評価だけで、正本の hash 検証・抜粋品質・Server 全体の応答時間は別途評価します。
- `--extraction-mode` または `--strategy` を指定すると、複製先の設定を変えて全文書を再抽出します。LLM を呼ぶので費用がかかります。
- bank の複製には `HINDSIGHT_API_ENABLE_DOCUMENT_EXPORT_API` と `HINDSIGHT_API_ENABLE_DOCUMENT_IMPORT_API`（どちらも既定で有効）が必要です。
- `--rerank` と `--extraction-mode` / `--strategy` は複製先の設定を `PATCH .../config` で変えるため、`HINDSIGHT_API_ENABLE_BANK_CONFIG_API`（既定で有効）も必要です。
- token は環境変数から読み、redirect には従いません。

## 検証

```sh
./scripts/check.sh
# ソースとパッチの一致だけを確認（ネットワーク不要）:
uv run --no-project scripts/sync_upstream.py --check
```

検証スクリプトは拡張テストとupstreamの全文検索・ベクトル検索の回帰テストを別プロセスで実行します。
upstreamのpytestフックが拡張テストへ影響するのを防ぐためです。
全テストは `.upstream/hindsight-api-slim/tests` に保持しますが、通常の検証では上記の関連テストに絞ります。
upstream更新時には追加・変更された関連テストを確認し、検証対象も更新してください。
`test_selects_rare_term_from_real_pg_stats` は実DBとupstreamのテスト環境が必要なため、通常の検証から除外します。

DB 統合テストは、専用の使い捨て DB を明示した場合だけ実行します。
テストごとに新しい `hindsight_test_<UUID>` スキーマを作成し、終了時にそのスキーマだけを削除します。
拡張はDB全体にインストールされるため、稼働中のアプリDBを指定しないでください。

```sh
# 接続文字列は環境変数へ安全に設定する
# HINDSIGHT_TEST_POSTGRES_URL: 通常PostgreSQL（vector / pg_trgm を利用可能にする）
# HINDSIGHT_TEST_LAKEBASE_URL: Lakebase Search を有効化した専用DB
uv run --locked pytest -m postgres -q
uv run --locked pytest -m lakebase -q
```

接続先未設定の統合テストは skip と表示します。通常 PostgreSQL では Lakebase の索引・順位付けを検証できません。
仕様参照: [Lakebase text](https://docs.databricks.com/aws/en/oltp/projects/lakebase-text)、
[Lakebase vector](https://docs.databricks.com/aws/en/oltp/projects/lakebase-vector)、[SudachiPy](https://github.com/WorksApplications/SudachiPy)。

## Phase 2: 処理設定・ログ・モデル固定

Dahlia Appの既定LLMは引き続き `HINDSIGHT_API_LLM_PROVIDER=databricks`、
`HINDSIGHT_API_LLM_MODEL=system.ai.gpt-6-luna`。処理を個別に変更する場合は標準の
`HINDSIGHT_API_{RETAIN,REFLECT,CONSOLIDATION,MENTAL_MODEL_REFRESH}_LLM_{PROVIDER,MODEL}` を使う。
providerを明示すると上流のprovider別既定モデルが選ばれるため、個別設定ではMODELも明示する。
未設定のRETAIN／REFLECT／CONSOLIDATIONは共通設定を、MENTAL_MODEL_REFRESHはREFLECTを継承する。
独自routingやモデル名変換はない。OAuthは既存App service principal経路を使う。
保守パッチはmental model refresh後の追加構造化呼び出しにもrefresh専用設定を適用する。

Dahlia Appは `HINDSIGHT_API_REFLECT_LLM_PROVIDER=databricks-responses` と同じMODELを設定し、
reflectと、それを継承するmental model refreshだけをResponses APIで呼び出す。
`system.ai.gpt-6-luna` のChat Completionsはreasoningを無効にしない限りfunction toolsを拒否するため、
tool呼び出しを伴う両処理はモデル既定のreasoningのままResponsesを使う。retainとconsolidationは
Chat Completionsのまま。AI Gatewayのpolicy block（HTTP 200）は両経路とも再試行しない固定エラーにする。
provider名はingestion policyに含まれるため、変更すると全bankの文書を再取り込みする。

rerankerは `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` の重みrevision
`1427fd652930e4ba29e8149678df786c240d8825` に固定した。起動時に既存の `huggingface_hub`
で必要なtokenizer／safetensorsのsnapshotを取得し、上流のローカルモデル設定へ渡す。
CPU／Databricks Apps LARGEは維持する。初回起動にはHugging Faceへの通信が必要で、取得失敗時に
moving revisionへフォールバックしない。UC Volume対応は含めない。

通常のreflect完了ログ、構造化エラー、OAuth例外、Uvicorn例外はAppのallowlist formatterを通す。
起動処理の例外も本文や資格情報を含むtracebackを出さず、固定の失敗メッセージで終了する。
`tests/test_processing.py`は合成マーカーを使って実上流reflectループと構造化処理を実行し、
stdout／stderrへの漏出を検査する。4処理のLLM設定とOAuth transportの検証は合成HTTP応答によるもので、
Databricks実起動や実データ品質評価の代替ではない。

従来の `scripts/evaluate_memory.py` はHindsight候補順位だけの比較。正本の認可・revision・最終抜粋・
主張を含む評価にはServerの `scripts/evaluate-memory.ts` を使う。dispositionを比較する場合は、
評価環境のbankに対して `/config` の `disposition_skepticism`、`disposition_literalism`、
`disposition_empathy` を変更し、同じ質問集合で比較する。`/profile` は410で廃止済み。
未評価の値を本番bankへ適用しない。派生データの旧entity削除には別途許可を必要とし、正本を変更しない。

## Phase 3: Knowledge Pages の公開記録

Server は既存の Workspace / Project mental model を利用する。上流の別ページ作成APIを呼ばず、full refresh・自動更新・削除検出を再利用する。保守パッチは refresh が既に使う DB cutoff と生成条件を `reflect_response.dahlia_generation` に保存し、bank-scoped fact detail に `updated_at` を添付する。Server は全根拠の変更時刻・系譜と Dahlia 正本を検証してから公開記録を作る。旧版にこの記録はないため、更新・検証までは非公開になる。bank削除や既存データの破壊的な作り直しは不要。

`uv run --locked pytest -q tests/test_knowledge_pages.py` は固定上流の実際の refresh 処理と fact detail serializer を合成データで検証する。Databricks App の実起動や実データによる品質評価の代わりにはならない。

### Ingestion recipe and Gateway policy boundary

The Dahlia adapter adds a digest of allowlisted effective extraction settings to `GET /banks/{bank}/config`. It includes the selected standard strategy, missions, processing model identities and entity policy, never credentials. Each retain subbatch checks the expected digest and stamps the actual recipe on document/fact metadata. Standard document reprocess accepts an optional `operation_id` and forwards it to upstream's existing idempotent retain submission; no new reprocessing engine is introduced.

Databricks service-policy blocks can arrive with HTTP 200 and a `databricks_service_policy` envelope. Text, structured and tool-call responses reject that envelope before interpreting its assistant content. Only `memory_policy_blocked` is retained as the error discriminator; block reasons are never copied. See [Databricks service policies](https://docs.databricks.com/aws/en/data-governance/unity-catalog/service-policies/). This does not enable Gateway policies, Memory Defense, PII redaction or general prompt-injection detection. In particular, the Gateway's model boundary does not guarantee redaction of original documents stored in Hindsight or canonical excerpts served by Dahlia/MCP.

The Server's operator-only `scripts/evaluate-memory-ingestion.ts` evaluates isolated extraction variants through final canonical publication. The older Python harness measures upstream candidate ranking only. Default concise extraction and no selected strategy remain unchanged; real-data selection is deferred.

### Phase 5: 明示的な画像取り込み

画像は既定無効です。Server の Workspace 管理者による opt-in と、以下の上流標準設定の両方が必要です。

```text
HINDSIGHT_API_VLM_PROVIDER=databricks
HINDSIGHT_API_VLM_MODEL=system.ai.gpt-6-luna
HINDSIGHT_API_LLM_VISION=true
HINDSIGHT_API_LLM_TEMPERATURE_RETAIN=none
HINDSIGHT_API_RETAIN_MAX_ATTACHMENTS_PER_CHUNK=1
HINDSIGHT_API_RETAIN_ATTACHMENT_MAX_COUNT=8
HINDSIGHT_API_RETAIN_ATTACHMENT_MAX_SIZE_MB=8
```

Databricks App は `HINDSIGHT_API_RETAIN_LLM_REASONING_EFFORT=low` も設定します。テキストと画像の事実抽出（VLM は retain の値を継承）だけに適用し、reflect・consolidation・Knowledge Pages はモデル既定のままです。`system.ai.gpt-6-luna` の実呼び出しで、テキストと合成画像の両方が `reasoning_effort: "low"` を受け付けることを確認しました。値は ingestion policy に含まれるため、変更すると全 bank の文書を再取り込みします。

`system.ai.gpt-6-luna` の実呼び出しで既定temperatureの拒否を確認したため、画像処理は標準設定でtemperatureを省略します。モデル名からの推測や別providerへの切り替えは行いません。

`concise` / `verbose` の抽出だけを許可し、`chunks` や Provider Batch は拒否します。能力をモデル名から推定しません。実際のモデルが画像に対応することは、既存 OAuth 経路による合成画像の実呼び出しで別途検証してください。ペイロードは Databricks の [Chat completion API](https://docs.databricks.com/aws/en/machine-learning/foundation-model-apis/api-reference) の `image_url` / base64 data URI を使い、モデル名変換や別 routing は行いません。

inline attachment を含む chunk のみ VLM に渡し、出力 16,000 token、120 秒、呼び出し内 retry 0 に制限します。出力上限には推論 token も含まれ、画像 chunk は同じ chunk の文字起こしも抽出対象にするため、4,096 token では `system.ai.gpt-6-luna` が `OutputTooLongError` で失敗しました。上限超過は同じ入力と予算では繰り返すとみなし、Hindsight worker は retry せずに operation を失敗させ、operation status に固定コード `memory_output_too_long` を返します。Server も retry せずに skip として表示し、管理者の「再試行」で再評価します。この扱いは画像 chunk の呼び出しに限り、reflect や Knowledge Pages の上限超過は従来どおり retry します。その他の失敗は外側の Dahlia operation の最大 3 回の retry に集約します。画像欠落・破損は固定エラーで失敗し、`[attachment unavailable]` によるテキストのみの成功にはしません。画像chunk由来のfactには構造化された画像contextを残し、上流のfact/attachment関係とServerのmanifestを公開前に照合します。内容や画像byteはログへ出しません。

設定APIは秘密情報を含まない `dahlia_images` 能力を返します。VLM、画像上限、抽出設定、固定処理予算のバージョンは ingestion policy に含まれ、変更時には派生文書・Knowledge Pagesを再検証します。bank を消す必要はありません。
