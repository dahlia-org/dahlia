# アプリ単位の依存管理

対象: Monorepo。採択: 2026-08-29。

各 TypeScript application が自身の manifest、pnpm version、lockfile を所有する。共有 TypeScript package がないため root pnpm workspace は不要な配置依存になり、廃止した。Desktop は SwiftPM を維持する。

Server の install、build、container context、CI、公開、環境変数と source path は `apps/server` を基準にする。Server の `pnpm-workspace.yaml` は package orchestration ではなく dependency build allowlist を保持する。

モノレポと root `deploy/` は維持し、DAB は `apps/server` だけを同期、共有可能な Cloudflare template は `deploy/cloudflare` に置く。root pnpm shortcut は持たず、package 間の実際の共有依存が生じるまで workspace orchestration を再導入しない。
