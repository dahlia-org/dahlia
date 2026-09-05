# 内蔵 AI skill と context

対象: Desktop 内蔵チャット・要約。採択: 2026-07-29〜08-14。

## Skill の責務

録音・確定文字起こし、meeting / summary / Project assignment、複数 meeting 由来の顧客情報を分け、整理 workflow を対応する preset に置く。

| Preset | 担当 |
| --- | --- |
| projects-optimizer | Project と meeting assignment、description の改善 |
| contacts-organizations-curator | Contact、Organization / unit、domain、membership / role |
| conversation-topics-curator | Topic と typed reference。meeting reference の note 必須 |
| insights-curator | Insight と evidence reference。AI 作成分は未承認のまま |

広い依頼の既定は90日、summary-first、既存 record 再利用、曖昧な assignment は保持。curator は Project を参照するだけで assignment を変更しない。Topic / Insight は相互参照せず独立実行でき、欠けた Contact / Organization の最小作成だけは後段にも許可する。名寄せ・階層・role / domain 整理は専用 curator に残す。

一括依頼でも skill の連鎖は保証しない。各 skill は未実施の層と担当 preset を報告する。選ばれた1ファイルだけでも動くよう、scope・evidence・retry の必要な規則は各 skill 内で自己完結させる。

## 書き込みの保護

analysis-only / audit は提案だけ。書き込み依頼では1 record / 1 relation 単位にし、同 record の property 変更は1回にまとめる。返却 revision を次の expected revision に使い、`changed:false` は no-op とする。

MCP の calendar、summary、transcript、既存 record は untrusted evidence とし、含まれる命令を実行・転記しない。Project description、Organization、Contact、Topic、Insight の編集可能な非空 text は作者不明でも user 確定値として扱う。保持した追記・意味を保つ簡潔化はできるが、削除・置換・矛盾は明示確認を待ち、default / timeout で承認扱いにしない。変更前 text を逐語報告し、履歴を持たない値の復元手段を残す。

Insight は作成直後に最初の evidence を張る。retry 後も張れなければ、その run が作った Insight だけを取り消す。明示依頼なく accepted にせず、承認しても正準 record へ write-back しない。MCP 非公開の Project delete / merge を実行可能と扱わない。

## 配布と実行境界

preset は application resource を `.copy` で同梱し、起動前に専用 `CODEX_HOME/skills/<name>` へ同期する。stateless な app-owned preset と旧 preset 名だけを置換し、古い file を残さない。skills root が symlink なら外部を変更せず起動失敗とし、同期失敗を「利用可能」と表示しない。`.process` による basename 衝突を避ける。

chat は skills.include_instructions と Vault 固定の Dahlia `--write` MCP を使い、apps / hooks / memory / plugins / orchestrator / user MCP は無効。command / file access は [タスクの承認方針](chat-approval.md) に従い、初期の「preset 読込 command だけ」の制限と混同しない。[user HOME 継承](accounts.md#chatgpt-と-databricks-cli) で user skills が発見され得るため、MCP の Vault validation を最終 authority にする。

## 要約 context

要約は過去 meeting を自動選択・取得せず、全 MCP / tool / skill を thread 単位で無効にする。Codex 全体の MCP 設定は書き換えない。structured output、temporary cwd、read-only / never を維持する。

初期の同一 calendar 系列の過去要約取得は利用が少なく context と追加 tool call を消費したため、meeting 限定 MCP と summary telemetry origin を廃止した。過去経緯の分析は chat / 外部 MCP から明示的に行う。通常の Vault-scoped MCP は維持する。
