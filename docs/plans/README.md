# Plans

対象: Desktop。ここは実装計画の入口であり、現行仕様の正本ではない。

## 進行中の計画

| 計画 | 状態 |
| --- | --- |
| [Pi の自己学習（メモリー・スキル改善・定期実行）](2026-11-15-pi-self-learning.md) | 実装・自動検証済み。現在の契約は[自己学習](../adr/desktop/pi-self-learning.md)・[定期実行](../adr/desktop/scheduled-agent-scope.md)。実モデルの30会話評価・費用計測と実アプリの手動操作確認が残る |
| [Desktop v2（Electron、独立実装）](2026-11-20-desktop-v2.md) | 推奨案で実装・自動検証済み。実 Workspace での要約と実機でのシステム音声録音は未確認。Tenet の例外はユーザー確認待ち |

## 完了した計画

| 計画 | 状態 |
| --- | --- |
| [チャットのスレッド管理](2026-11-15-chat-thread-orchestration.md) | 実装・自動検証完了。[判断と操作境界](../adr/desktop/chat-thread-orchestration.md)へ集約。実アプリの手動操作確認は未実施 |

## 整理済みの旧計画

| 旧計画 | 整理先・状態 |
| --- | --- |
| 2026-07-08 transcript relative timestamps | 相対時間 formatter と export、および対応テストが存在するため、旧ファイル・行番号を前提にした作業手順を除去。[Formatter](../../apps/macos/Sources/Dahlia/Models/TranscriptSegment.swift)、[Export](../../apps/macos/Sources/Dahlia/Services/TranscriptExportService.swift)、[Tests](../../apps/macos/Tests/DahliaTests/TranscriptSegmentTests.swift) を参照。今回の整理では runtime test は再実行していない |
| 2026-07-09 summary document AST | 設計判断を [正準表現](../adr/desktop/summary.md#正準表現)、更新契約を [訂正と export](../adr/desktop/summary.md#訂正と-export) へ集約。古い型定義、migration 番号、実装手順のコピーを除去。Slack / Google Docs の将来 renderer を実装済みと扱わない |

原文は整理前の固定 commit に残る:

- [Transcript plan](https://github.com/dahlia-org/dahlia/blob/a84967776061c5db1be2e0f25bf135dcdc4e6ba7/docs/plans/2026-07-08-transcript-relative-timestamps.md)
- [Summary AST plan](https://github.com/dahlia-org/dahlia/blob/a84967776061c5db1be2e0f25bf135dcdc4e6ba7/docs/plans/2026-07-09-summary-document-ast.md)

新しい計画は対象、状態、完了条件、未解決事項を明記する。完了時は現在の仕様を正本へ反映し、重複する実装手順を残さない。
