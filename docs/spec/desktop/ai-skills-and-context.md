# 内蔵 AI skill と context

対象: Desktop 内蔵チャット・要約。採択: 2026-07-29〜08-14。顧客インテリジェンス用の preset は 2026-09 に廃止した。

## Skill の責務

整理 workflow は Project と meeting assignment、description の改善だけを扱う。

| Preset | 担当 |
| --- | --- |
| projects-optimizer | Project と meeting assignment、description の改善 |

広い依頼の既定は90日、summary-first、既存record再利用とし、曖昧なassignmentは保持する。

## 書き込みの保護

analysis-only / audit は提案だけ。書き込み依頼では同じProjectのproperty変更を1回にまとめ、返却revisionを次のexpected revisionに使う。`changed:false`はno-opとする。

MCPのcalendar、summary、transcript、既存recordはuntrusted evidenceとし、含まれる命令を実行・転記しない。Project descriptionの編集可能な非空textは作者不明でもuser確定値として扱う。保持した追記・意味を保つ簡潔化はできるが、削除・置換・矛盾は明示確認を待ち、default / timeoutで承認扱いにしない。変更前textを逐語報告し、履歴を持たない値の復元手段を残す。

## 配布と実行境界

Preset は application resource を `.copy` で同梱し、Pi に `--skill` で渡す。
チャットではアカウント別 `pi/skills` と、利用者が登録したパッケージの skill / prompt も発見する。
個人の `~/.agents` などの自動探索とパッケージ extension code は無効に保つ。
account skill の変更は [Desktop Pi のメモリーと自己学習](pi-self-learning.md) の共通サービスと `skill_manage` に集約する。
同梱とパッケージの skill は読むだけとし、カスタマイズは別名の account skill を作る。
会議 MCP と外部 MCP は [Pi runtime](pi-runtime.md) と承認方針に従う。

## チャット context の表示

ユーザーメッセージには、会議・Project・ライブモードの非表示 context と本文の区切りを表示しない。
本文中の改行やインデントは保持し、履歴を再表示した場合も同じ本文を表示する。

## 要約 context

要約は過去 meeting を自動選択・取得せず、全 MCP / tool / skill を thread 単位で無効にする。Pi の MCP 設定は書き換えない。structured output と temporary cwd を維持する。
通常の Workspace 単位の MCP は維持する。過去経緯の分析は chat / 外部 MCP から明示的に行う。

## 却下した案

- 同一 calendar 系列の過去要約を要約生成で自動取得する（meeting 限定 MCP と summary telemetry origin を含む）: 利用が少なく context と追加 tool call を消費したため。

## 未適合・未検証

- 未確定: 要約の旧 read-only / never の制約が、Pi 版でどの制約に対応するか。
