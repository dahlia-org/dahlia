# ADR-0034: 構造化 summary の本文をローカル検索対象にする

- Status: Accepted
- Date: 2026-08-21
- Amends: ADR-0005, ADR-0033
- Builds on: ADR-0001

## Context

ADR-0005 と ADR-0033 は meeting 検索を metadata に限定していたため、保存済み summary にしかない決定や議題を検索できない。summary はローカル SQLite にある再生成可能な二次情報であり、文字起こしより短く、既存の bounded FTS projection で扱える。

## Decision

- `SummaryDocument` の section heading と block 本文を出現順に平坦化し、FTS の単一 `summary` field に索引する。document title、description、tags、action items、JSON key、UUID、screenshot ID、transcript reference は含めない。
- summary field は meeting description と同じ evidence class とする。アプリは summary 一致時に本文 snippet を「要約」と表示する。
- MCP とアプリの通常 FTS を同じ本文へ拡張する。比較用の simple literal substring 検索は metadata のみを対象とする。
- summary の insert、document update、delete は meeting job を coalesce する。decode 不能な document は空本文として扱い、metadata 検索を失敗させない。
- v36 は contentless FTS table を安全に作り直して全件再構築する。正本 meeting、project、summary と registry は保持する。
- transcript 原文・翻訳文は引き続き検索対象にしない。検索本文をテレメトリ、ログ、外部サービスへ送らない。

## Consequences

- summary の生成・訂正・削除後、非同期索引が追いつくと通常検索へ反映される。simple 検索は summary 本文を対象にしない。
- 既存 DB は migration 後の再構築完了まで検索 unavailable になるが、録音、文字起こし、metadata、summary の永続化を待たせない。
- contentless FTS に元本文は保存せず、検索結果 snippet は正本 SummaryDocument から再生成する。

## References

- [ADR-0001](0001-summary-document-ast.md)
- [ADR-0005](0005-vault-scoped-meeting-access-mcp.md)
- [ADR-0033](0033-use-local-fts5-search-projection.md)
