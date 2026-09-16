# Hindsight + Lakebase

Hindsight API の固定版に、`lakebase_text` / `lakebase_vector` バックエンドを追加した独立サービスです。
Python 3.11–3.14、Git、uv を使用します。Dahlia のアプリケーション連携は含みません。

## Databricks Apps への配備

`deploy/databricks` の DAB は Hindsight を Dahlia Server と別の Databricks App として配備します。Lakebase project と `databricks-postgres` database は共有し、Hindsight のテーブルと migration ledger は既定の `hindsight` PostgreSQL schema に分離します。

App 起動時に Databricks が注入する `PG*` 変数と `LAKEBASE_ENDPOINT` から接続を作り、共有拡張 `vector`、`pg_trgm`、`lakebase_text`、`lakebase_vector` が `public` にあることを advisory lock 下で確認してから migration を実行します。Lakebase の短命 credential は `/api/2.0/postgres/credentials` から App service principal で取得し、asyncpg の新規接続ごとに自動更新します。別 schema に既存拡張がある場合はデータを破壊せず起動を停止します。`databricks` providerはApp service principalのclient credentialsでOAuth tokenを更新し、AI Gatewayの`gpt-5-6-luna`と`qwen3-embedding-0-6b`をOpenAI互換APIで使用します。ユーザーのOBO tokenとDatabricks secretは使用しません。詳細は [`deploy/databricks/README.md`](../../deploy/databricks/README.md) を参照してください。

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
`slim` 構成なので、例では外部 embedding プロバイダーを使い、ローカル機械学習モデルの依存は追加していません。
HTTP API・認証設定は [upstream のドキュメント](https://hindsight.vectorize.io/)を参照してください。

`pyproject.toml` で公開 PyPI を既定のレジストリに指定しています。
`uv.lock` の参照先も公開 PyPI に統一し、固定済みのバージョンと配布ファイルのハッシュは維持しています。

## バックエンドの選択

| 環境変数 | 追加した値 | 処理 |
| --- | --- | --- |
| `HINDSIGHT_API_TEXT_SEARCH_EXTENSION` | `lakebase_text` | `tsvector` + `lakebase_bm25`、BM25関連度 |
| `HINDSIGHT_API_VECTOR_EXTENSION` | `lakebase_vector` | `vector` + `lakebase_ann`、cosine距離 |
| `HINDSIGHT_API_LLM_PROVIDER` | `databricks` | App service principalでAI GatewayのOpenAI互換`chat/completions`を呼び出す |
| `HINDSIGHT_API_EMBEDDINGS_PROVIDER` | `databricks` | 同じ認証でAI GatewayのOpenAI互換`embeddings`を呼び出す |
| `LAKEBASE_ENDPOINT` | Databricks Apps resource binding | 設定時にApp service principalの短命DB credentialへ自動で切り替える |

独立して指定できます。未指定時は upstream の `native` / `pgvector` のままです。
既存のバックエンドも維持しています。Lakebase は PostgreSQL バックエンドでのみ利用できます。
`databricks` provider の既定 URL は `${DATABRICKS_HOST}/ai-gateway/mlflow/v1` です。同じ workspace origin の別経路は
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
- `--version` での更新時だけタグを解決し、`uv add --no-sync hindsight-api-slim==X.Y.Z` で依存指定と lockfile を更新します。
  成功後にソース・固定情報・`pyproject.toml`・lockfileを切り替えます。前のチェックアウトは `.upstream-backup-*` に残します。
- パッチ競合・依存解決失敗では現行のソース・固定情報・`pyproject.toml`・lockfileを変更しません。
  作業用チェックアウトに未保存の変更や未追跡ファイルがある場合も停止します。

現在の基準は正式リリース **v0.9.2**、コミット
`ebad478240d3171bb88201ececda5e8d9883d22d` です。
`pyproject.toml` の `hindsight-api-slim==0.9.2` と `uv.lock` で依存を固定しています。

### バージョンを更新する

```sh
# X.Y.Z を対象の正式リリースに置き換える
uv run --no-project scripts/sync_upstream.py --version X.Y.Z
uv sync --locked
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
| `engine/llm_wrapper.py` | `databricks` を API key 不要の OpenAI 互換 provider として既存ディスパッチへ登録 |
| `engine/providers/openai_compatible_llm.py` | App service principal の短命 OAuth token を各 LLM リクエストへ供給 |
| `engine/embeddings.py` | 同じ認証と AI Gateway URL を使う `databricks` embedding provider を登録 |
| `engine/vector_index_health.py` | 既存の索引健全性チェックが lakebase_ann を認識するための登録 |
| `config.py` | 全文検索の選択値追加と PostgreSQL 以外での誤設定拒否 |
| `_vector_index.py` | 拡張名・ANN索引句・検索設定を既存ディスパッチへ登録 |
| `migrations.py` | 未変更の履歴を互換設定で実行し、選択された全文検索だけ初期設定。ANN型の識別、次元変更時の bank 別索引管理の維持、mental_models の既存索引の対応 |
| `engine/sql/postgresql.py` | Lakebase BM25 SQL とクエリ処理への分岐 |
| `engine/search/retrieval.py` | BM25 の候補上限・prefilter を検索トランザクション内に限定 |
| `engine/db/ops_postgresql.py` | 通常保存・インポートが使う共通バッチ保存で本文と検索用データを同時更新 |
| `engine/memories/pg/writes.py` | 編集・復元の直接SQL後、既存トランザクション内で更新 |
| `engine/consolidation/consolidator.py` | 観察の新規作成・更新・重複統合の直接SQL後、既存トランザクション内で更新 |
| `engine/memory_engine.py` | ページ作成・更新・名称変更・内容クリアの直接SQLで同時更新し、ページ検索にもBM25設定を適用 |
| `engine/transfer/importer.py` | 共通 `_restore_rows` の一箇所でページの本文保存と検索用データを同時更新 |

他バックエンドでは追加のDB処理・トークナイズ・Lakebase初期設定を実行しません。
既存のトランザクションがある保存経路では、それをそのまま利用します。

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
