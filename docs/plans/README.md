# Plans

対象: Desktop。ここは実装計画の入口であり、現行仕様の正本ではない。現在、このディレクトリに進行中の計画はない。

## 整理済みの旧計画

| 旧計画 | 整理先・状態 |
| --- | --- |
| 2026-07-08 transcript relative timestamps | 相対時間 formatter と export、および対応テストが存在するため、旧ファイル・行番号を前提にした作業手順を除去。[Formatter](../../apps/desktop/Sources/Dahlia/Models/TranscriptSegment.swift)、[Export](../../apps/desktop/Sources/Dahlia/Services/TranscriptExportService.swift)、[Tests](../../apps/desktop/Tests/DahliaTests/TranscriptSegmentTests.swift) を参照。今回の整理では runtime test は再実行していない |
| 2026-07-09 summary document AST | 設計判断を [正準表現](../adr/desktop/summary.md#正準表現)、更新契約を [訂正と export](../adr/desktop/summary.md#訂正と-export) へ集約。古い型定義、migration 番号、実装手順のコピーを除去。Slack / Google Docs の将来 renderer を実装済みと扱わない |

原文は整理前の固定 commit に残る:

- [Transcript plan](https://github.com/dahlia-org/dahlia/blob/a84967776061c5db1be2e0f25bf135dcdc4e6ba7/docs/plans/2026-07-08-transcript-relative-timestamps.md)
- [Summary AST plan](https://github.com/dahlia-org/dahlia/blob/a84967776061c5db1be2e0f25bf135dcdc4e6ba7/docs/plans/2026-07-09-summary-document-ast.md)

新しい計画は対象、状態、完了条件、未解決事項を明記する。完了時は現在の仕様を正本へ反映し、重複する実装手順を残さない。
