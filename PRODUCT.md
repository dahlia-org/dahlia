# Dahlia Product Tenets

この文書は、Dahlia が何を提供し、何を提供しないかを判断するためのプロダクト原則の正本である。
機能の採否、scope の境界、外部サービスとの関係、AI と人の役割分担はここを基準に決める。
どう作るかの技術契約は [`ARCHITECTURE.md`](ARCHITECTURE.md)、実装時の必須ルールは各スコープの `AGENTS.md`、
過去の判断理由は [ADR index](docs/adr/README.md) を参照する。

- `PRODUCT.md`: 何を作り、何を作らないか。tenet と競合時の優先順位
- `ARCHITECTURE.md`: 現在の構成、横断的な設計原則、未適合箇所
- `AGENTS.md`: 実装時のルーティングと必須ガードレール
- `docs/adr/`: 決定時点の背景、選択肢、トレードオフ

tenet は個別の機能仕様ではなく、仕様を決めるときの判断基準である。実装や仕様が tenet と矛盾する場合は、
仕様側を変更するか、tenet を変更する ADR を先に追加する。既成事実として tenet を書き換えない。

最終確認日: 2026-08-12

## Positioning

Dahlia は、会議の音声を取りこぼさずに記録し、その記録から必要な文脈を AI に組み立てさせる、
個人が単独で使う macOS ネイティブアプリである。

- 主な利用者: 顧客との会議を継続的に持ち、発言と経緯を自分の判断材料にしたい個人
- 中心となる仕事: 録る → 失わずに残す → 後から根拠付きで辿れる形にする → 整理・要約・分析は AI に任せる
- 提供する価値: 会議中に手を動かさなくても、後から一次データに遡れる状態が残ること

Dahlia でないもの:

- チームで共有する議事録プラットフォーム、顧客マスタ (CRM)、SFA
- 業務システム間を接続する統合ハブや iPaaS
- クラウド常時接続を前提としたサービス

## Tenets

各 tenet は、主張、根拠、設計上の判断、許容する例外、誤読しやすい点で構成する。

### T1. 整理と分類は AI が行い、人は行わない

**主張**: データの整理、分類、関連付け、要約は最終的にすべて AI が行う。人に残す入力は、AI が判断できない、
または本人しか決められない意思決定に限る。

**根拠**: 会議記録の価値は蓄積量に比例するが、人手による整理コストも同じ速度で増える。人が整理し続ける前提の
設計は、データが増えた時点で必ず破綻する。

**設計上の判断**:

- 初期リリースで人が手作業する UI を提供してよい。ただしその機能は、同じ操作を AI が実行できる粒度の
  Repository API と MCP tool を前提に設計する。人だけが到達できる整理操作を作らない。
- AI が逐次書き込む前提のため、操作は単数、冪等、検証可能な単位に分割する ([ADR-0012](docs/adr/0012-reviewable-customer-intelligence-workspace.md))。
  暗黙の一括変換に依存しない。
- AI の主張 (Insight) と正準レコードを分離し、AI 出力の形や信頼度を durable schema に固定しない
  ([ADR-0011](docs/adr/0011-vault-scoped-customer-intelligence.md))。Insight の確認は正準レコードを書き換えない。
- 人が確定した値を自動処理が黙って上書きしない。ユーザーが編集した Organization 名などは、後続の自動観測より優先する。

**許容する例外**: 統合、削除、誤りの訂正など、影響が不可逆または本人しか判断できない操作は人が確定する。

**誤読しやすい点**: 「AI に全部やらせる」は「確認なしに自動反映する」ではない。実行を AI に任せることと、
変更を後から確認・取り消しできることは両立させる。T1 は T3 に優先しない。自動化のために録音と文字起こしの
保全を緩めない。

### T2. 顧客データの正本は所属企業の CRM であり、Dahlia は自分の整理のために Organization と Contact を持つ

**主張**: Salesforce などの企業 CRM を事業上の正本とし、Dahlia はそれと直接連携しない。Dahlia の Organization と
Contact は、自分の会議記録を辿るためのローカルな整理軸である。

**根拠**: CRM と同期した瞬間、Dahlia は企業のデータ品質、権限、監査、スキーマ変更に従属する。個人が単独で
使える範囲を保つには、事業データの正本を持たないことが条件になる。

**設計上の判断**:

- CRM や SFA への同期、書き戻し、ID マッピングを実装しない。
- Contact の identity は `UUID + (vaultId, email)` のローカル identity であり、Vault 横断や全社の人物 identity では
  ない ([ADR-0011](docs/adr/0011-vault-scoped-customer-intelligence.md))。
- 組織と人物は、会議参加者という観測から必要な範囲だけを作る。企業の組織図を完全に再現しない。
- Dahlia 内部では SQLite が Organization と Contact の技術的な source of truth である。これは「Dahlia が顧客マスタの
  正本である」ことを意味しない。この二つの意味を混同しない。

**許容する例外**: ユーザーが自分で CRM へ転記するための書き出しは許容する。Dahlia が CRM の API を呼ぶことは
許容しない。

**誤読しやすい点**: 「正本ではない」は「不正確でよい」ではない。ローカルの整理軸としての一貫性、すなわち Vault
境界、参照の整合、削除時の後始末は保証対象である。

### T3. 録音と文字起こしはすべての源泉であり、何としても死守する

**主張**: 音声と確定文字起こしは再取得できない唯一の一次データである。要約、Insight、分析、UI 表示はすべて
そこから再生成できる派生物として扱う。

**根拠**: 会議は再現できない。整理や要約は後からやり直せるが、その場の発言は失われたら戻らない。

**設計上の判断**:

- 音声フレームと確定文字起こしの永続化は、MainActor や UI の完了を待たない
  ([Reliability Scope](ARCHITECTURE.md#reliability-scope))。
- 欠落を成功や無音として扱わない。queue overflow と永続化失敗は明示的な録音エラーにする。
- 負荷に応じて集約、破棄、再生成してよいのは、再生成可能な UI projection だけである。音声フレーム、確定文字起こし、
  確定翻訳、録音 range は、UI の都合で破棄しない
  ([Failure and Overload Policy](ARCHITECTURE.md#failure-and-overload-policy))。
- 録音音声は検証済みの immutable segment として保存し ([ADR-0004](docs/adr/0004-protect-recordings-with-segmented-immutable-storage.md))、
  データベースは schema generation 付きで backup と restore ができる ([ADR-0007](docs/adr/0007-version-and-restore-sqlite-backups.md))。
- 新機能は録音クリティカルパスに同期依存を追加しない。顧客インテリジェンスの取り込みのような補助処理は、
  録音開始が成功した後の best effort とし、失敗しても録音を巻き戻さない。

**保証範囲**: 防ぐ対象は、アプリのハング、UI 停止、負荷による欠落である。プロセス全体の crash、強制終了、OOM、
OS やストレージ自体の障害は現時点の保証対象外であり、範囲の拡張は ADR で決める。

**誤読しやすい点**: 「死守する」は「あらゆる障害に耐える」ではない。保証する障害と対象外の障害を明示し、
対象外を暗黙に保証したことにしない。また「一次データから派生している」ことは「破棄してよい」ことを意味しない。
確定翻訳のようにユーザーが確定した派生データは durable work であり、保全対象は
[Workload Classes](ARCHITECTURE.md#workload-classes) の分類で判断する。

### T4. 他サービスへの連携を Dahlia に実装せず、MCP で外部の AI とツールに任せる

**主張**: Dahlia から外部サービスを操作する機能を増やさない。代わりに Vault 単位で安全に読める interface を
提供し、統合は外部の AI とツールに行わせる。

**根拠**: 連携先ごとの認証、レート制限、スキーマ変更、権限モデルを Dahlia が抱えると、アプリの中核が外部サービスの
都合で壊れる。統合の組み合わせは無限にあるが、データの提供口は一つでよい。

**設計上の判断**:

- 新しい外部サービス連携の要求は、まず MCP tool として外部エージェントが実現できないかを検討する。
- MCP は Vault UUID を認可境界とし、既定は read-only、書き込みは明示的な `--write` に限定する
  ([ADR-0005](docs/adr/0005-vault-scoped-meeting-access-mcp.md), [ADR-0010](docs/adr/0010-database-canonical-bounded-project-hierarchy.md))。
- MCP が返す内容は untrusted data として扱い、指示として実行しない。
- 連携先が増えるほど価値が上がる、という前提を採らない。連携数ではなく、一次データの質と辿りやすさで価値を測る。

**許容する例外**: 操作が限定的で疎結合な入出力は許容する。ファイル書き出し、要約のエクスポート、カレンダーからの
読み取りのように、失敗しても録音と文字起こしに影響しない一方向の境界を保つこと。内蔵 Codex の任意の model-provider
transport は業務システム統合ではなく、既存の AI 付加機能の接続境界として扱う
([ADR-0029](docs/adr/0029-offer-an-optional-codex-ai-gateway.md))。

**誤読しやすい点**: 「連携しない」は「閉じる」ではない。Dahlia 側の統合実装を増やさない代わりに、外部から
使える読み取り口は意図的に整備する。外部エージェントが Dahlia の MCP と他サービスの MCP を併用することは
Dahlia の scope 外であり、妨げない。

### T5. 中核はスタンドアローンで完結させる

**主張**: 録音、文字起こし、閲覧、検索という中核機能は、ネットワーク、外部アカウント、クラウドサービスなしで
完結する。

**根拠**: 会議は、ネットワークが不安定でも、アカウントが期限切れでも始まる。中核が外部依存を持つと、最も
失いたくない場面で失う。

**設計上の判断**:

- 文字起こしはリアルタイムもバッチも Apple Speech の `SpeechTranscriber` が on-device で行い、録音音声を外部へ
  送信しない。WhisperKit は付加機能であるバッチ自動言語判定で言語を選ぶためだけに使い、文字起こし自体は行わない。
- 同期を使わない会議データと端末固有ファイルはローカルの SQLite と file system だけで完結する。Vault ごとに明示的に同期を有効化した場合、SQLite は即時反映できる offline working copy とし、
  Vault 名、Project の名前・説明・階層、meeting metadata、summary、transcript 原文、screenshot、OCR、AI caption の canonical record を Dahlia Server と同期してDesktop／Webから利用できる。翻訳文と音声は同期しない
  ([ADR-0056](docs/adr/0056-add-owner-only-meeting-sync.md), [ADR-0066](docs/adr/0066-sync-vault-projects-and-separate-transcript-speakers.md), [ADR-0067](docs/adr/0067-use-domain-transactions-and-cursor-deltas-for-sync.md))。Server record は個人所有を維持し、owner が複数の特定 organization
  または特定 Team へ明示した場合だけ read-only 共有できる。Header認証のuserは固定`external` Organizationへ所属する
  ([ADR-0065](docs/adr/0065-unify-header-sharing-with-external-organization-teams.md))。
- Server の任意 Hybrid 検索は同期済み summary、OCR、AI caption と検索時の query 原文を設定済み embedding
  provider へ送信できる。Dahlia は query 原文を保存・ログ出力しない。
  vector は再生成可能な projection とし、未設定、再構築中、障害時も全文検索へ縮退してローカルの中核機能を妨げない
  ([ADR-0062](docs/adr/0062-add-server-hybrid-search-projection.md))。
- 外部依存は付加機能に閉じ込め、未設定または失敗時も中核が動作する degradation を設計に含める。
- 認証やアカウント設定を中核機能の前提にしない。

**許容する例外**: 疎結合な付加機能は外部依存を持ってよい。Google Calendar と EventKit の読み取り、Google Docs や
Drive への書き出し、Codex による要約生成、Sparkle の更新確認、Sentry の障害報告、TelemetryDeck の匿名利用計測、
バッチ自動言語判定の初回モデル取得、任意の meeting sync と明示的な read-only 共有がこれにあたる。Codex の接続先として任意の Dahlia Server Gateway を選ぶ場合も
同じ境界に置き、いずれも中核の前提条件にしない。

**誤読しやすい点**: 「スタンドアローン」は「オフライン専用」ではない。外部機能を持つこと自体は否定せず、
中核がそれに依存しないことを要求する。

## 競合時の優先順位

複数の tenet が競合する場合は、上位を優先する。

| 順位 | Tenet | 競合時に守るもの |
| --- | --- | --- |
| 1 | T3 | 録音と確定文字起こしの保全 |
| 2 | T5 | 中核機能が単独で動作すること |
| 3 | T2 | 事業データの正本を持たないという scope の境界 |
| 4 | T4 | Dahlia 側に統合実装を増やさないこと |
| 5 | T1 | 整理と分類を AI に寄せること |

適用例:

- 録音中の Insight 自動生成 (T1) が capture の安定性を損なうなら、T3 を優先して録音停止後の処理に回す。
- CRM を直接呼ぶ tool は、MCP 経由でも採用しない。T4 を満たしても上位の T2 に反する。
- 要約品質のために外部サービスを必須化する提案は、T5 を優先して付加機能に留める。

## 機能提案のチェック

新機能や仕様変更は、次を順に確認する。

1. 録音クリティカルパスに同期依存を追加するか。追加するなら設計をやり直す。
2. 中核機能がネットワーク、アカウント、外部サービスを必要とするようになるか。なるなら付加機能へ分離する。
3. Dahlia を顧客マスタや業務システムの正本にするか。するなら採用しない。
4. Dahlia が外部サービスの API を呼ぶか。呼ぶなら、まず MCP で外部エージェントに任せられないかを検討する。
5. 整理や分類を人の継続作業として要求するか。要求するなら、同じ操作を AI が実行できる API を先に定義する。
6. 初期リリースで人手の UI を先行させるか。5 を満たすなら許容する。

## Out of scope

現在の tenet の下では採用しない。

- 共同編集
- CRM や SFA との双方向同期
- クラウドでの音声処理と保管
- 汎用の統合ハブ、ワークフロー自動化
- Vault 横断または全社の人物 identity 解決

これらは永久禁止ではない。採用が必要になった場合は、tenet を更新する ADR を先に追加し、この文書と
`ARCHITECTURE.md` の保証範囲を同時に見直す。

## 参照

- [`ARCHITECTURE.md`](ARCHITECTURE.md): 信頼性の保証範囲、workload class、負荷時の縮退順序
- [ADR index](docs/adr/README.md): 各 tenet を具体化した決定と、その置換関係
- [Customer intelligence workspace](docs/customer-intelligence-workspace.md): T1 と T2 を反映した現在の画面仕様
- [Project workspaces](docs/project-workspaces.md): T4 の read/write 境界を含む Project 運用
