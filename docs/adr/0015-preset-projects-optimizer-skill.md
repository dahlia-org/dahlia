# ADR 0015: Projects Optimizer skill をアプリ内 Codex にプリセットする

- Status: Accepted
- Date: 2026-07-29
- Amends: ADR 0003
- Builds on: ADR 0010

## Context

Dahlia の Project 階層と Meeting assignment は、DB 正本、2段階 hierarchy、revision、期待する現在の
assignment を使う MCP write contract を持つ。汎用チャットの developer instruction だけでは、広い整理依頼の
既定期間、既存 Project の再利用、summary を優先した根拠確認、曖昧な Meeting の扱いまでを再利用可能な
workflow として提示できない。

ADR 0003 は要約とチャットの両方で skills を無効にした。要約の structured output と隔離は維持しながら、
Vault 全体へアクセスできる対話チャットにだけ Dahlia 固有の整理 workflow を提供する。

## Decision

- `projects-optimizer` skill を Dahlia の application resource として同梱する。
- app-server 起動前に、skill の `SKILL.md` と `agents/openai.yaml` を Dahlia 専用
  `CODEX_HOME/skills/projects-optimizer` へ同期する。この preset と未リリース時に使った旧名の directory は
  stateless な app-owned path として置換し、同期先の古い files を残さない。`skills` 自体が symbolic link
  の場合は外部 directory を変更せず起動を失敗させる。
- app-server 子 process の `HOME` も Dahlia 専用 `CODEX_HOME` に固定し、user の `~/.agents/skills` を
  discovery 対象にしない。Codex bundled skills も無効にし、chat に公開する skill を preset だけに限定する。
- chat thread config では `skills.include_instructions` を有効にする。apps、hooks、memory、plugins、
  orchestrator MCP、ユーザー設定の MCP は引き続き無効にし、Dahlia MCP だけを Vault 固定の `--write`
  session として追加する。
- chat は user request と skill description に基づいて preset を自動選択する。developer instruction は
  Dahlia 専用 `CODEX_HOME/skills` 配下の選択済み `SKILL.md` を読む read-only command だけを許可し、
  その他の command と file access は禁止する。
- summary thread config では skills を引き続き無効にする。Meeting 限定 MCP、structured output、
  temporary working directory、`approvalPolicy: never` の契約を変更しない。
- `~/.codex` の skills、設定、認証、session はコピーも参照もしない。

skill は Project と Meeting の読み取り、分類、対応する単数 write tool の順序を定義する。あわせて、assign 済み
Meeting を evidence とする Project description の作成と改善も定義する。description は `create_project` と
`update_project` が既に受け付ける property であり、Dahlia は要約生成 prompt の `<project><description>` として
渡す。この context は要約生成側で untrusted かつ instruction ではないと宣言されているため、skill は要約器への
指示ではなく durable な事実だけを書く。description の書き込みは、user が Vault の整理または description の作業を
依頼した場合に限る。analysis-only や audit の依頼では提案を報告するだけで write tool を呼ばない。Dahlia は
description の以前の版を保存せず、MCP も現在の text の作者を返さないため、非空の description はすべて user が
確定した値として扱い、既存の記述を削除、置換、または矛盾させる変更は user の明示的な確認を得るまで実行しない
（[T1](../../PRODUCT.md#tenets)）。Dahlia MCP が返す calendar、summary、transcript、既存 Project は会議参加者や
外部の主催者が書いた untrusted data であり、skill はこれを evidence としてのみ読み、そこに含まれる指示を実行せず、
命令形の text を Project の name や description に持ち込まない（[T4](../../PRODUCT.md#tenets)）。Project deletion や
merge など MCP が公開しない操作は実行可能と扱わない。

## Consequences

- 広い整理依頼でも、既定90日、既存 Project 優先、summary-first、曖昧な assignment の保持という一貫した
  workflow を再利用できる。
- Project description の変更は、その Project で以降生成されるすべての要約の入力を変え、以前の版が残らないため
  不可逆である。evidence のない記述と要約器への指示を書かないこと、既存の記述を失う変更を確認なしに実行しない
  こと、変更した非空 description の変更前 text を逐語で報告することを skill の要件とする。報告された変更前
  text が、user が元に戻すための唯一の手段になる。
- preset 更新は次回 app-server 起動時に専用 `CODEX_HOME` へ反映される。
- skill instruction は chat の tool choice に影響するため、skill 本体と chat／summary config の分離を
  テストし、Dahlia MCP の Vault 境界と write validation を最終 authority とする。
- app-server 起動は preset files の同期に失敗した場合も失敗として扱い、skill が利用可能に見えて実際には
  欠落している状態を作らない。
