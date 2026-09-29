# アプリ単位の依存管理

対象: Monorepo。採択: 2026-08-29。

各 TypeScript application が自身の manifest、pnpm version、lockfile を所有する。共有 TypeScript package がないため root pnpm workspace は不要な配置依存になり、廃止した。Desktop は SwiftPM を維持する。

Server の install、build、container context、CI、公開、環境変数と source path は `apps/server` を基準にする。Server の `pnpm-workspace.yaml` は package orchestration ではなく dependency build allowlist を保持する。

モノレポと root `deploy/` は維持し、DAB は `apps/server` だけを同期、共有可能な Cloudflare template は `deploy/cloudflare` に置く。root pnpm shortcut は持たず、package 間の実際の共有依存が生じるまで workspace orchestration を再導入しない。

Server の wire 契約は `@hono/zod-openapi` が所有し、`openapi-typescript` と `openapi-fetch` が Web の型・通信を生成する。Desktop は Apple `swift-openapi-generator` を build plugin として使い、`swift-openapi-runtime` / `swift-openapi-urlsession` を runtime に使用する。`DahliaServerAPI/openapi.json` は Server の committed spec を参照し、別の手書き DTO を正本にしない。

## Documents 同梱資材（2026-09-29）

[Documents ADR](../shared/documents.md) により、`apps/server/src/documents` の runtime 非依存コアとエディタを Desktop / Web / Server で共有する。独立 package / root pnpm workspace は追加しない。`apps/server` の pinned Yjs / Tiptap / ProseMirror 依存を既存 tsup で IIFE に bundle し、Desktop の Resources/Documents に JS と全同梱依存のライセンスをコミットする。Swift ビルド・実行に Node や CDN は不要。`pnpm documents:build` で更新し、`pnpm documents:check`（`pnpm check` に含む）で生成物を検証する。正本は TypeScript ソースであり、生成 JS を直接編集しない。
