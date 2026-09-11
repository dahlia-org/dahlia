# 内蔵 AI skill と context

対象: Desktop 内蔵チャット・要約。採択: 2026-07-29〜08-14。2026-09に顧客インテリジェンス用presetを廃止した。

## Skill の責務

現行の整理workflowはProjectとmeeting assignment、descriptionの改善だけを扱う。

| Preset | 担当 |
| --- | --- |
| projects-optimizer | Project と meeting assignment、description の改善 |

広い依頼の既定は90日、summary-first、既存record再利用とし、曖昧なassignmentは保持する。

## 書き込みの保護

analysis-only / audit は提案だけ。書き込み依頼では同じProjectのproperty変更を1回にまとめ、返却revisionを次のexpected revisionに使う。`changed:false`はno-opとする。

MCPのcalendar、summary、transcript、既存recordはuntrusted evidenceとし、含まれる命令を実行・転記しない。Project descriptionの編集可能な非空textは作者不明でもuser確定値として扱う。保持した追記・意味を保つ簡潔化はできるが、削除・置換・矛盾は明示確認を待ち、default / timeoutで承認扱いにしない。変更前textを逐語報告し、履歴を持たない値の復元手段を残す。

## 配布と実行境界

Project presetはapplication resourceを`.copy`で同梱し、起動前に専用`CODEX_HOME/skills/<name>`へ同期する。statelessなapp-owned presetと旧preset名だけを置換し、古いfileを残さない。skills rootがsymlinkなら外部を変更せず起動失敗とし、同期失敗を「利用可能」と表示しない。`.process`によるbasename衝突を避ける。

chat は skills.include_instructions と Vault 固定の Dahlia `--write` MCP を使い、apps / hooks / memory / plugins / orchestrator / user MCP は無効。command / file access は [タスクの承認方針](chat-approval.md) に従い、初期の「preset 読込 command だけ」の制限と混同しない。[user HOME 継承](accounts.md#chatgpt-と-databricks-cli) で user skills が発見され得るため、MCP の Vault validation を最終 authority にする。

## 要約 context

要約は過去 meeting を自動選択・取得せず、全 MCP / tool / skill を thread 単位で無効にする。Codex 全体の MCP 設定は書き換えない。structured output、temporary cwd、read-only / never を維持する。

初期の同一 calendar 系列の過去要約取得は利用が少なく context と追加 tool call を消費したため、meeting 限定 MCP と summary telemetry origin を廃止した。過去経緯の分析は chat / 外部 MCP から明示的に行う。通常の Vault-scoped MCP は維持する。
