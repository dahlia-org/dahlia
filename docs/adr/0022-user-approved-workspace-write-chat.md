# ADR-0022: アプリ内チャットを workspace-write とユーザー承認で実行する

## Status

Accepted

## Date

2026-08-04

## Context

ADR-0003 は、要約と汎用テキストチャットの両方を `sandbox: read-only` で開始し、app-server から届く approval request を
fail-closed で `decline` する設計にした。ADR-0012 はそのうえで、チャットの `turn/start` に `approvalsReviewer = "auto_review"`
を渡し、顧客インテリジェンスの write tool を Codex 側の reviewer subagent に評価させることにした。

この auto review は Codex 側で reviewer 用のモデル呼び出しを行う。Databricks (Unity) AI Gateway を model provider にした
構成ではその経路が利用できず、承認を伴う操作が成立しない。要約は `approvalPolicy: never` で approval request 自体が発生
しないため影響を受けないが、チャットは reviewer が機能しない限り write tool もコマンド実行も進まない。

fail-closed の前提は「チャットは tool を利用しない」だった。ADR-0011 と ADR-0012 で Dahlia MCP の write tool を使うように
なり、ADR-0015 と ADR-0017 で preset skill の SKILL.md を読むためのコマンド実行も必要になったため、この前提はすでに
チャットには当てはまらない。

## Decision

要約以外、すなわちアプリ内 AI チャットについて、sandbox とレビュー主体を変更する。要約 thread は変更しない。

| | thread | sandbox | approvalPolicy | approvalsReviewer | approval request |
|---|---|---|---|---|---|
| AI 要約 | `ephemeral: true`、temporary cwd | `read-only` | `never` | 指定しない | fail-closed で `decline` |
| AI チャット | `ephemeral: false`、Vault ごとの workspace | `workspace-write` | `on-request` | `user` | ユーザーへ提示して決定を返す |

- `thread/start` と `thread/resume` の `sandbox` を `workspace-write` にする。書き込み可能な範囲は
  `CodexChatWorkspaceLocating` が返す Vault ごとの workspace ディレクトリと一時ディレクトリに限られる。
- `turn/start` の `approvalsReviewer` を `user` にする。適用条件は provider に依存せず、ChatGPT サブスクリプション接続でも
  同じ挙動にする。provider ごとに承認主体が変わると、同じ rollout を別 provider で再開したときに承認履歴の意味が変わる。
- 各 `turn/start` は、応答待ちとは独立したローカル turn handle を先に作成する。この handle が start request、wire turn ID、
  approval request、停止タイマー、terminal event を接続世代ごとに所有する。`turn/started` または start response で wire ID を
  確定し、別 turn や再接続前の request ID を現在の UI へ流用しない。
- `item/commandExecution/requestApproval` と `item/fileChange/requestApproval` は、対象 `threadId` と `turnId` が同一のローカル
  turn handle に属する場合だけ `CodexChatSessionModel` へ配送する。ユーザーの決定は元の JSON-RPC id に返し、
  `serverRequest/resolved` で同じ承認だけを UI から除く。利用可能な操作は server の `availableDecisions` と交差させ、
  `acceptWithExecpolicyAmendment` は server が構造化 decision で提示し、`proposedExecpolicyAmendment` と完全一致する規則だけを
  UI に表示して返す。command の包括的な `acceptForSession` は、許可範囲を説明できないため表示しない。
- 要約 thread と未知の thread からの approval request は従来どおり `decline` する。判定は「チャット thread として登録済みか」
  だけで行い、subscriber の有無では判定しない。`turn/start` の応答より approval request が先着し得るため。
- `item/permissions/requestApproval` は fail-closed のままとする。これは sandbox 外への権限昇格要求であり、応答が
  `GrantedPermissionProfile` という別形式を必要とする。workspace-write の範囲では通常発生しない。
- `grantRoot`、追加 filesystem permission、network permission を含む要求は、この UI で許可できる範囲外として扱う。
  workspace と temporary directory の境界は sandbox が決め、承認 UI がその境界を拡張しない。
- UI に渡す承認 prompt は正規化時に合計 20 KB、file change 50 件、decision 16 件、exec policy rule 50 件へ制限する。
  file change の add/delete/update/move も承認対象の説明に含める。上限を超えた要求、必要な command/diff/kind が欠ける要求、
  未対応の権限要求は fail-closed とし、server が `decline` を許す場合だけ拒否を表示する。有効な decision がない場合でも停止操作は
  残す。未加工の巨大 payload を presentation state に保持しない。
- app-server から turn parser、session model までの projection stream は件数上限を持つ。overflow や protocol error では event を
  黙って欠落させず、対象 turn を停止する。raw turn routing の overflow は承認要求を見失う可能性があるため共有接続を再起動する。
- v1 互換の `applyPatchApproval` と `execCommandApproval` も従来どおり `denied` を返す。

## Invariants

- 未応答の approval request を残さない。ユーザーの決定、turn の完了、subscriber の終了のいずれかで必ず解決する。
  transport が失われた場合は応答せず登録だけ破棄する。
- approval への最初の応答者は、送信で actor を離れる前に JSON-RPC id の所有権を確定する。ユーザー操作、停止、terminal event が
  競合しても同じ id へ二重応答しない。
- 停止操作は未応答の approval を `cancel` で閉じてから `turn/interrupt` を送る。approval を待っている間 server は turn を
  完了できないため、interrupt だけでは停止しない。wire turn ID がまだ確定していない場合、または terminal event が期限内に
  届かない場合は、対象を推測せず共有 app-server 接続を再起動する。
- 同じ thread の購読は lease で所有する。古い画面が解放されても、別画面の lease が残る限り `thread/unsubscribe` を送らない。
  最終 lease の削除と unsubscribe の送信は app-server actor 内で連続して開始し、新しい owner の resume より後へずらさない。
- 要約 thread の `approvalPolicy: never` と `sandbox: read-only` は変更しない。
- 承認 UI に表示するコマンド、パス、理由を診断ログや Sentry へ送らない。

## Consequences

良い影響:

- Databricks AI Gateway でもチャットの write tool と preset skill のコマンド実行が動作する。
- 承認の主体が明示的になり、何が実行されようとしているかをユーザーがその場で確認できる。
- reviewer subagent 用の追加のモデル呼び出しがなくなる。

トレードオフ:

- チャットが workspace ディレクトリへ書き込めるようになる。書き込み範囲は sandbox が制限するが、read-only ではなくなる。
- 承認プロンプトの分だけユーザーの操作が増える。file change は同じファイル群、command は表示した exec policy rule に限って
  同一セッション内の再確認を抑えられる。
- Dahlia が approval の状態機械を持つことになり、未応答のまま turn が終わる経路をテストで固定する必要がある。
- 安全な停止のため、wire turn ID を特定できない稀な競合では app-server を再起動し、同じプロセス上の他の処理も再接続する。

## References

- ADR-0003: Codex app-server をアプリ共有の長寿命 AI バックエンドとして使う
- ADR-0012: 単一顧客の組織ビューと単数 CRUD による逐次AI更新
- `CodexChatService`: `Sources/Dahlia/Services/CodexChatService.swift`
- approval routing: `Sources/Dahlia/Services/CodexAppServerService.swift`
- 承認 UI: `Sources/Dahlia/Views/CodexChat/CodexChatApprovalView.swift`
