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

汎用 Agent を外部公開せず、内蔵 Agent と MCP は同じ bounded tools を使う。Hooks とクライアントプラグインは含めない。呼び出しタイミングは利用者のクライアント指示に依存する。既存の個人の回答設定とスレッド Observational Memory は引き続き別の保存契約を持ち、全文を MCP に公開しない。
