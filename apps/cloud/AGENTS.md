# Dahlia Cloud Service Guide

This package is an optional AI control plane. It must never become a prerequisite for recording, transcription, browsing, or search in the macOS app.

- Keep authenticated application APIs under `/api/**` and the Codex-compatible surface under `/api/v1/**`.
- Never log or persist Responses request/response bodies, transcripts, images, tool input/output, bearer tokens, provider secrets, or local paths.
- Read provider credentials from runtime secrets only. Persist public Model Aliases, but never expose or persist provider credentials.
- Keep authentication and storage differences behind runtime adapters; use one OpenAI-compatible upstream adapter. Do not import Node-only modules from the Worker entry point.
- Stream upstream response bodies without buffering. Buffer request JSON only after enforcing the configured byte limit.
- Personal workspaces are deterministic identity claims in this MVP. Do not add organizations, invitations, team sharing, or per-organization providers without a new approved ADR.
- Better Auth migrations are committed SQL files and run explicitly. Never mutate an existing migration after release.

Validation from the repository root:

```bash
pnpm check
```
