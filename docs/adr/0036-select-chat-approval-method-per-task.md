# ADR-0036: AI チャットの承認方法をタスクごとに選択する

## Status

Accepted

## Date

2026-08-22

## Context

ADR-0022 と ADR-0027 は、AI provider に応じた固定の承認ポリシーを定めた。Codex app-server は thread の
設定更新と turn ごとの承認設定を受け取れるため、利用者は作業内容に応じて承認方法を選択できる。

## Decision

- AI チャットは承認方法をタスク単位で保持し、各 turn に次の組み合わせを明示する。
  - 承認を求める: `on-request`、`user`、`workspaceWrite`
  - 代わりに承認: `on-request`、`auto_review`、`workspaceWrite`
  - フルアクセス: `never`、`user`、`dangerFullAccess`
- 「代わりに承認」は ChatGPT Subscription だけで有効にする。Databricks への切り替え時と service 境界では
  「承認を求める」へ戻す。
- 新規タスクは ChatGPT Subscription では「代わりに承認」、それ以外では「承認を求める」を初期値にする。
  「フルアクセス」は自動選択しない。
- 選択変更を `thread/settings/update` へ順番に保存し、履歴からの再開時に復元する。不明な設定と従来の
  `never` + `readOnly` は「承認を求める」として安全側へ正規化する。`never` + `dangerFullAccess` の完全一致だけを
  「フルアクセス」として復元する。
- 「フルアクセス」は警告表示された明示的な選択を同意として扱い、次の turn から適用する。追加の確認
  ダイアログは設けない。
- 要約 thread、DB、テレメトリは変更しない。

## Consequences

利用者は安全境界と操作量をタスクごとに選べる。保存済みタスクと実行中 turn の設定が異なる可能性があるため、
各 turn は送信時の選択を固定し、設定更新失敗はチャット内で設定更新として再試行できるようにする。

「フルアクセス」では承認プロンプトなしで filesystem と network を利用できるため、通常の workspace-write より
強い警告表示が必要になる。

## Relationships

- ADR-0022 と ADR-0027 を改訂する。
- ADR-0023 の Vault MCP 承認 UI と fail-closed 処理は、承認を求める turn に引き続き適用する。
