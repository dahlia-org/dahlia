# ADR-0047: pnpm 依存をアプリ単位で管理する

- Status: Accepted
- Date: 2026-08-29
- Amends: ADR-0029, ADR-0044

## Context

Dahlia Server は Databricks Apps、Cloudflare Workers、Node container、npm package として macOS アプリとは独立して配置する。共有 TypeScript package はなく、root pnpm workspace は Server のデプロイに不要な manifest と directory layout への依存を追加していた。

## Decision

- モノレポと repository-level `deploy/` は維持する。
- 各 pnpm application が自身の `package.json`、pnpm version、lockfile を所有し、repository root の pnpm workspace と package manifest は廃止する。Server の `pnpm-workspace.yaml` は複数 package を列挙せず、pnpm 11 が要求する dependency build allowlist だけを保持する。
- Dahlia Server の環境変数、container context、CI、package publication、deployment source path は `apps/server` を基準にする。
- DAB は bundle 外の `apps/server` だけを同期し、Cloudflare の共有可能な deployment template は `deploy/cloudflare` に残す。

## Consequences

- Dahlia Server は `apps/server` 単位で install、build、container 化、Databricks Apps 配置ができる。
- repository root からの pnpm shortcut と workspace 横断 command はなくなる。
- TypeScript package 間で実際の共有依存が生じるまでは workspace orchestration を再導入しない。
