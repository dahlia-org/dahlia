# Hindsight Integration Guide

These rules apply to every change under `apps/hindsight`, not only provider integrations.

## Preserve upstream compatibility

- Treat compatibility with future upstream Hindsight releases as a design constraint for all changes.
- Prefer Dahlia-owned adapters in `src/`, startup wiring in `scripts/`, and focused tests over changes to upstream-owned files.
- `.upstream/` is generated from `UPSTREAM.json` plus `patches/hindsight-api-slim.patch`. Never commit it or treat edits there as the source of truth.
- When an upstream edit is unavoidable, keep the diff narrowly scoped and regenerate `patches/hindsight-api-slim.patch` from the exact revision pinned in `UPSTREAM.json`. Do not copy or fork whole upstream modules into Dahlia-owned code.
- Keep deployment-only behavior out of upstream migrations and defaults when environment wiring or an adapter can supply it.

## Required workflow

1. Run `uv run --no-project scripts/sync_upstream.py --check` before editing to verify that the materialized checkout matches its pin and patch.
2. Implement Dahlia-owned code first. If upstream files must change, use `.upstream/hindsight-api-slim` only as a temporary patch worktree and export the complete diff to `patches/hindsight-api-slim.patch` before finishing.
3. Run `uv run --no-project scripts/sync_upstream.py --check` again. It must verify the revision, patch hash, and materialized diff.
4. Run the focused regression tests plus `scripts/check.sh`. If `uv.lock` changes, regenerate `requirements.txt` from the locked project as well.

## Updating Hindsight

- Update only to an explicit upstream release with `uv run --no-project scripts/sync_upstream.py --version <version>`; never follow a moving branch.
- If the maintained patch no longer applies, rebase its smallest necessary hunks onto a clean checkout of that release, regenerate the patch, and rerun the integration tests. Do not solve conflicts by pinning indefinitely or vendoring more upstream source.
- Review upstream release notes and changed call sites covered by each maintained hunk. Remove local hunks when upstream has absorbed the behavior.
