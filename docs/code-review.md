# Dahlia コードレビューガイド

この文書は、Codex managed review、ローカルの `codex review`、Claude の `/code-review`、実装後のセルフレビューで共有する。
重大なレビュー規則は最も近い `AGENTS.md` の `## Code Review Rules`、技術的な正本は `ARCHITECTURE.md` と関連 ADR に置き、
ここでは finding の採用基準とレビュー時の確認方法を定める。

## レビューの準備

1. 変更されたファイルと実行経路を確認し、適用されるすべての `AGENTS.md` を読む。
2. diff だけで判断せず、呼び出し元、状態の owner、失敗経路、関連テストを必要な範囲で確認する。
3. `AGENTS.md` の Documentation Router から、変更に関係するアーキテクチャ節だけを読む。
4. レビュー依頼は read-only として扱い、修正も明示的に依頼された場合だけ編集する。

## Finding の採用基準

変更によって導入または顕在化する、到達可能で具体的な欠陥だけを finding とする。各 finding には次を含める。

- 問題のある最小の file／line 範囲
- 発生させる入力、状態、順序、負荷などの trigger
- ユーザー、録音、文字起こし、永続データ、セキュリティ、応答性への具体的な impact
- 違反する Dahlia の契約、または欠陥を防げていない検証上の根拠
- 契約を保つ修正方向。広い redesign が必要なら、勝手に設計を確定せず必要な判断を明記する

重大度は到達可能性と影響に基づけ、レビュー画面に表示させるために水増ししない。Codex の GitHub review が重大な finding
だけを投稿する場合でも、根拠の弱い懸念を重大な欠陥として扱わない。

次は原則として finding にしない。

- 実行可能な失敗経路を示せない一般論または推測上の性能懸念
- 挙動や保守上の欠陥を隠していない style、format、命名上の好み
- lint、format、型検査など CI が決定的に判定する問題
- 変更範囲と無関係な既存問題
- テストがないという事実だけの指摘。現実的な回帰が検証されていない場合は、その回帰と影響を finding として説明する

finding がない場合はその旨を明記し、実行できなかった検証や手動確認などの residual risk を分けて報告する。

## Dahlia 固有のチェック

### 契約と変更範囲

- 依頼された挙動以外の recording、transcription、settings、schema、MCP、backup 契約を変えていないか。
- 新しい coordinator、store、repository、worker が既存 owner と責務を重複していないか。
- target state と異なる実装を、現在の実装例だけを根拠に正当化していないか。

### Recording、Persistence、停止処理

- capture callback と recording-critical lane が短時間、有界、non-suspending で MainActor を待たないか。
- UI、observer、preview、cache、外部 I/O が audio acceptance または finalized persistence を gate していないか。
- queue／stream に容量、overflow の意味、終了、cancellation、drain の所有者があるか。
- failure、overflow、partial stop を成功やデータ欠落として隠していないか。
- 正常停止が新規受付を閉じた後、文書化された順序で in-flight work を drain するか。

### Concurrency とハング耐性

- actor、lock、task、callback の lifecycle と mutable state の owner が明確か。
- lock 内で I/O、外部 callback、unbounded allocation、`await` を実行していないか。
- `Task.detached`、`@unchecked Sendable`、`@preconcurrency import` が ownership や data race を隠していないか。
- MainActor の一時停止中にも recording-critical work と durable ingress が進行できるか。
- interactive work と speculative work を同じ直列経路に置いて priority inversion を起こしていないか。

### UI、描画、更新頻度

- MainActor は表示状態の反映と短い計算に限定され、DB、disk、network、同期 OS query、入力サイズ依存の decode／parse を待たないか。
- 高頻度イベントごとに全文 parse、全件 materialization、重い layout、無制限な task 作成や state publication をしていないか。
- UI projection は window、件数、byte cost、更新頻度、同時実行数などデータ特性に合う上限を持つか。
- 画面、選択対象、入力世代が変わったときに不要な処理を cancel し、identity または generation で stale completion を捨てるか。
- raw content や durable source of truth を切り詰めることと、再生成可能な projection を制限することを混同していないか。

更新頻度制御はイベントの意味から選ぶ。

- `debounce`: 入力が止まった後に処理する意味があり、連続入力中に結果が出なくてもよい場合
- `throttle`: 連続入力中も一定間隔で進捗または表示を更新する必要がある場合
- `coalescing`: 複数イベントをまとめても意味と順序を保てる場合
- `latest-wins`: 古い中間結果を破棄でき、現在の状態だけが必要な rebuildable work

これらを audio frame を落としたり、確定文字起こし、確定翻訳、保存操作の durable ingress を遅延または欠落させたりする
根拠にしない。正本が保たれる rebuildable UI projection にだけ適用し、変更時は burst、cancellation、stale completion、
MainActor stall、UI catch-up のうち影響する境界を検証する。

### Database とユーザーデータ

- 登録済み migration の name、order、body を変更していないか。
- released user の行、関係、識別子、意味を削除、再解釈、孤立させないか。
- 新しい migration が直前 schema の既存行を保持し、空 DB への全 migration 適用にも成功するか。
- UI または recording-critical path が同期 DB transaction を待たないか。

### 検証の証拠

- bug fix には修正前に失敗し修正後に通る regression test、または同等の再現可能な証拠があるか。
- concurrency／UI test が固定 sleep ではなく観測可能な state、event、timeout を使うか。
- 実行結果は exit code だけでなく、意図した test 数と suite が実際に走ったことまで確認されているか。
- 実行できなかった build、test、lint、manual check が成功扱いされず、理由と次の確認方法が報告されているか。

## 規則の保守

新しい規則は、confirmed false negative、繰り返されるレビュー説明、または新しい重大な契約が生じたときに追加する。

1. 問題を含む代表差分と、安全な実装の代表差分を用意する。
2. 既存規則で検出できない理由を確認し、重複や矛盾を先に除く。
3. 「指摘する挙動」「影響」「安全な経路または例外」を含む最小の規則を、最も近い `AGENTS.md` に追加する。
4. 詳細説明または複数領域にまたがるチェックだけをこの文書へ追加する。
5. 同じ差分で見逃しと false positive を再評価し、ノイズを生む規則は狭めるか削除する。
6. 決定的に検出できる問題は test、lint、CI へ移し、レビュー規則から外す。
