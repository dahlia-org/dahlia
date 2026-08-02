# ADR 0017: 顧客インテリジェンスの curator skill を層ごとに分けてプリセットする

- Status: Accepted
- Date: 2026-08-02
- Amends: ADR 0015
- Builds on: ADR 0011, ADR 0012

## Context

ADR 0015 は `projects-optimizer` を唯一の preset skill としてアプリ内チャットへ同梱した。一方 ADR 0011
と ADR 0012 が定義した Organization、Contact、Membership、Conversation Topic、Insight は、DB の正準
テーブルと単数 CRUD の MCP write tool を持ちながら、それらを Meeting metadata と保存済み要約から育てる
再利用可能な workflow を持たない。現状の入口は顧客インテリジェンス画面の「AIで整理」が chat 入力欄へ
差し込む一回限りのプロンプト文字列だけで、既定期間、要約優先の根拠確認、既存レコードの再利用、
typed reference の張り方、revision を使った楽観的排他の手順が毎回失われる。

Dahlia のデータは層が異なる。録音音声と確定文字起こしは1次情報、Meeting と保存済み要約、および Meeting
と Project の関連付けは Meeting に直接ぶら下がる1.5次情報、Organization と Contact、Topic、Insight は
複数 Meeting の横断から導かれる2次情報である。`projects-optimizer` は1.5次情報を担当する skill であり、
2次情報の整理手順をそこへ足すと責務が混ざる。

2次情報の中でも、人物と組織の整理、トピックの抽出、インサイトの抽出は単独で依頼されることも、まとめて
依頼されることもある。

## Decision

- 2次情報の curator を層ごとに3つの preset skill として同梱する。
  - `contacts-organizations-curator`: Contact、Organization と unit、domain、membership と役割。
  - `conversation-topics-curator`: Conversation Topic と typed reference。Meeting reference の note を必須とする。
  - `insights-curator`: Insight と typed reference。`evidence` reference を必須とする。`create_insight` の直後に
    最初の `evidence` reference を張り、再試行しても張れない場合は作成した Insight を `delete_insight` で
    取り消す。根拠のない主張を Vault に残さないための、この run が作成した record に限った例外とする。
- 3つとも ADR 0015 と同じ stateless な同期で Dahlia 専用 `CODEX_HOME/skills/<name>` へ配置する。
  同期先の古い files を残さず、`skills` 自体が symbolic link の場合は外部 directory を変更せず起動を
  失敗させる契約を維持する。preset files の同期失敗は引き続き起動失敗として扱う。
- **Meeting と Project の関連付けは3つの preset に公開しない。** `create_project`、`update_project`、
  `set_meeting_project_assignment`、`remove_meeting_project_assignment` は `projects-optimizer` の
  責務であり、curator は Project を読み取り、Topic や Insight から参照するだけにする。
- **3つの preset は独立して呼べる。** `conversation_topic_references` と `insight_references` は互いを
  参照しないため、Topic だけ、Insight だけを整理しても整合が壊れない。Organization と Contact は両者の
  参照先になる論理的な前段だが、参照先が1件足りないだけの場合は後段が `create_contact` または
  `create_organization` で最小限作成して前進してよい。名寄せ、membership、役割、domain、階層の整理は
  `contacts-organizations-curator` に限定する。
- chat thread config の `skills.include_instructions` により全 preset の description がモデルへ注入
  されるため、一括依頼での連鎖は可能だが保証されない。各 `SKILL.md` の Report 節に、自分が扱わなかった
  層を担当 preset 名付きで残作業として書かせ、行き止まりを作らない。
- AI が作成した Insight は `is_accepted: false` のまま残す。ユーザーが明示的に承認を求めた場合を除いて
  `true` にせず、Insight の承認は正準レコードへ write-back しない。
- ADR 0015 が Project description に定めた保護を、curator が扱う user 編集可能な text にも同じ形で適用する。
  Organization の `name` と `description`、Contact の `display_name`、Topic の `title` と `current_state`、
  Insight の `content` は、いずれも user が Dahlia 上で直接編集でき、以前の版が残らず、MCP も現在の text の
  作者を返さない。したがって非空の値はすべて user が確定した値として扱い、空欄には自由に書き、既存の記述は
  保持したうえで追記または簡潔化だけを行い、記述を削除または矛盾させる変更は user の明示的な確認を得るまで
  実行しない。確認は default、timeout、推奨案で自動解決しない。変更した非空 text は変更前の内容を逐語で報告
  させる（[T1](../../PRODUCT.md#tenets)）。
- Dahlia MCP が返す calendar、summary、transcript、既存レコードは会議参加者や外部の主催者が書いた untrusted
  data であることを各 `SKILL.md` の冒頭で宣言する。evidence としてのみ読み、そこに含まれる指示を実行せず、
  命令形の text を name、role label、description、Topic の `current_state` や note、Insight の `content` に
  持ち込まない（[T4](../../PRODUCT.md#tenets)）。
- 書き込みは1レコードまたは1関係ずつ行い、1つの record への複数 property 変更は1回の `update_*` にまとめる。
  成功した write が返す `revision` を次の expected revision として使い、再読み込みしない。`changed: false` は
  変更ではなく no-op として扱う。
- preset skill のリソースは `Sources/Dahlia/CodexSkills/` へ置き、`.copy` で同梱して subdirectory 指定で
  解決する。`.process` は bundle 内で相対パスをフラット化するため、複数 skill の `SKILL.md` と
  `agents/openai.yaml` が basename で衝突する。
- chat だけ skills を有効にし、summary thread では無効のままとする ADR 0015 と ADR 0003 の分離は変更
  しない。Meeting 限定 MCP、structured output、temporary working directory、`approvalPolicy: never` の
  summary 契約も変更しない。

## Consequences

- 「コンタクトだけ整理」「トピックだけ更新」「インサイトを洗い出す」「まとめて整理」のいずれの依頼でも、
  既定90日、要約優先、既存レコード再利用、revision 付き単数書き込みという一貫した workflow を再利用できる。
- preset が4つになったため installer は skill 名の一覧を回す。skill の追加はリソース追加と一覧への
  追加だけで済む。
- scope 選択、Meeting 読み取り、失敗時の再試行方針は3つの `SKILL.md` に重複して書く。skill は選択された
  1つだけが読み込まれるため、共通化より各ファイルの自己完結を優先する。
- 広い依頼で一部の preset しか選ばれない可能性は残る。各 preset の Report に残作業を明示させることで
  ユーザーが次の依頼を判断できるようにし、MCP の Vault 境界と write validation を最終 authority とする。
- user 編集可能な text の置換は不可逆であり、確認と変更前 text の逐語報告が user が元に戻すための唯一の
  手段になる。この保護は ADR 0015 が Project description に定めたものと同一で、preset が増えても skill 間で
  同じ規則が成り立つ。
