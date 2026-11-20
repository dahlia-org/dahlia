# Artifact storage / API / MCP / Web（廃止）

対象: Server。採択: 2026-08-29〜09-01。廃止: 2026-09-08（リリース前の v1 整理）。

Artifact 機能は廃止した。Server は Artifact の REST API、Web 導線、Artifact の MCP 書き込みツールと公開型を持たない。PostgreSQL / SQLite / D1 の Artifact テーブルは追加 migration で削除し、旧 migration は保持する。Desktop は Artifact の書き出しを行わない。既存のオブジェクトの実体は削除しない。

Files・録音音声・会議データの read-only MCP は維持する。共有ストレージ実装は `apps/server/src/storage/` にあり、`createApp` の引数は `objectStorage` とする。互換エイリアスは持たない。Desktop の既存の書き出し履歴は読み取り可能なまま保持し、Google Docs とローカル書き出しを維持する。

Remote MCP の transport と認証の契約は [Server の Remote MCP](remote-mcp.md) に置く。
