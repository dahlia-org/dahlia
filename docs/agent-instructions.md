# エージェント指示の保守方針

この文書は、Dahlia の `AGENTS.md` を更新するときの判断基準を記録する。実行時に常に必要なルールだけを `AGENTS.md` に置き、背景説明や保守手順はここへ分離する。

## 基本方針

GPT-5.6 には、手順を細かく固定するより、成果、重要な制約、利用できる根拠、完了条件を明確に伝える。既に安定している一般的な振る舞いは説明せず、Dahlia 固有の判断を変える情報を優先する。

`AGENTS.md` に残す情報:

- ユーザーから見た成果と、完了と判断する条件
- データ保全、依存追加、外部操作などの制約と承認境界
- アーキテクチャの所有関係や、ツール選択に影響するルーティング規則
- 実行可能なビルド・テストコマンドと、結果の判定方法
- 失敗時に止まる条件、最小限のフォールバック、報告事項

`AGENTS.md` から外す情報:

- 上位または下位の指示ファイルと同じルールの繰り返し
- モデルが既に安定して行う一般的な作業手順
- 現在の一時的な計画、過去の実装経緯、変更されやすい一覧のスナップショット
- 実測した失敗を直していない例や、曖昧な「常に簡潔に」「効率的に進める」などの表現

`ALWAYS`、`NEVER`、禁止表現は、ユーザーデータの破壊防止など真の不変条件に限定する。それ以外は、質問、検索、再試行、検証を選ぶための判断条件を書く。

## 階層

- ルートの `AGENTS.md`: リポジトリ全体の目的、権限境界、技術的前提、共通の完了条件
- `apps/macos/Sources/Dahlia/AGENTS.md`: アプリ固有の所有関係、並行処理、UI とローカライズ
- `apps/macos/Sources/Dahlia/Database/AGENTS.md`: データ保全とマイグレーション
- `apps/macos/Tests/DahliaTests/AGENTS.md`: テストの隔離、実装規約、実行結果の判定
- `docs/code-review.md`: 複数のレビュー手段で共有する finding の採用基準、チェックリスト、保守手順

同じルールが複数階層に必要に見える場合は、上位に成果または制約を置き、下位にはその階層でだけ必要な実装条件を置く。`CLAUDE.md` は `AGENTS.md` へのシンボリックリンクなので直接編集しない。

## レビュー指示の配置

レビュー規則は、Codex managed review、ローカルの `codex review`、Claude の `/code-review`、実装後のセルフレビューで同じ正本を使う。

- リポジトリ全体または subtree 固有の重大な制約: 最も近い `AGENTS.md` の `## Code Review Rules`
- finding の採用基準、出力に必要な根拠、レビュー専用チェックリスト: `docs/code-review.md`
- 機能の採否、scope の境界、AI と人の役割分担: `PRODUCT.md`
- 現在の ownership、workload、failure mode、UI responsiveness の契約: `ARCHITECTURE.md`
- 判断の経緯または既存決定の変更: 関連する ADR
- format、lint、型検査など決定的に判定できる規則: test、lint、CI
- 一つの PR だけで必要な観点: PR コメントまたはそのレビュー依頼

Skill やプラグインには、レビューの起動、外部 reviewer の利用、finding の triage などのワークフローだけを置く。
Dahlia 固有の制約を Skill ごとに複製しない。`CLAUDE.md` のシンボリックリンクと `AGENTS.md` からの参照により、
Codex と Claude の両方を同じ規則へ誘導する。

`## Code Review Rules` には、レビューで繰り返し説明する重大な規則を各 scope につき少数だけ置く。規則は
「指摘する挙動」「発生する影響」「安全な経路または例外」を含め、関数名や一時的な実装詳細ではなく持続する契約として書く。
詳細な背景や全チェック項目は `docs/code-review.md` または正本のアーキテクチャ文書へ分離する。

## 更新と評価

1. 実際の失敗例または新しい要件を特定する。
2. 矛盾、重複、古い例を先に削除する。
3. 決定的に検出できる問題は、レビュー指示ではなく test、lint、CI へ移す。
4. 一度に 1 グループだけ変更し、その失敗を直す最小の指示を追加する。
5. 問題を含む差分と安全な差分の両方で、見逃しと false positive を確認する。
6. 小さなコード修正、UI のローカライズ、DB マイグレーション、テストのみの変更など、代表的な依頼で確認する。
7. 成果の達成、不要な確認回数、検証漏れ、false positive、指示の総量を変更前後で比較する。

短くなったこと自体を成功とせず、必要な制約、根拠、検証結果を保ったまま代表的な作業の成功率が落ちないことを基準にする。

## 参照

- [Using GPT-5.6 — Prompting best practices](https://developers.openai.com/api/docs/guides/model-guidance?model=gpt-5.6#prompting-best-practices)
- [Prompting guidance for GPT-5.6 Sol](https://developers.openai.com/api/docs/guides/prompt-guidance-gpt-5p6)
- [Codex code review in GitHub](https://learn.chatgpt.com/docs/third-party/github)
- [Custom instructions with AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
