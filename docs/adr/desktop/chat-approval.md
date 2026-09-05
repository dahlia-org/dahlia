# チャットの書き込みと承認

対象: Desktop 内蔵チャット。採択: 2026-08-04〜08-22。

## タスクごとの実行方針

| 選択 | Approval policy / reviewer / sandbox |
| --- | --- |
| 承認を求める | on-request / user / workspaceWrite |
| 代わりに承認 | on-request / auto_review / workspaceWrite。ChatGPT Subscription のみ |
| フルアクセス | never / user / dangerFullAccess。警告付きの明示選択のみ |

新規タスクは ChatGPT なら代理承認、それ以外はユーザー承認。フルアクセスを自動選択しない。Databricks / 未知 provider で代理承認を選んでも service 境界でユーザー承認へ戻す。

変更は順序を保って `thread/settings/update` に保存し、次 turn から適用する。送信済み turn は設定を固定し、設定保存失敗は独立して再試行できる。不明設定と旧 never + readOnly はユーザー承認、never + dangerFullAccess の完全一致だけをフルアクセスとして復元する。明示選択に追加確認 dialog は重ねない。

要約は ephemeral / temporary cwd / read-only / never / 全 tools 無効のまま。通常 chat の writable 範囲は Vault ごとの workspace と一時領域。フルアクセスだけは filesystem / network の制約が広がることを明示する。

## Approval の相関と停止

応答前に local turn handle を作り、start request、wire turn ID、approval、timer、terminal event を connection generation ごとに所有する。先着した approval も登録済み chat turn と ID で相関し、subscriber の有無で可否を決めない。

command / file approval は server の available decisions との共通部分だけを示す。exec-policy amendment は提示された構造化 rule と完全一致する場合だけ返し、command の包括的 acceptForSession は表示しない。file change の add / delete / update / move も説明する。

- prompt は合計20 KB、file change 50件、decision 16件、exec rule 50件に制限する。欠落・超過・未対応要求は許可しない。拒否可能な選択肢がなくても停止は残す。
- 未応答 request は user decision、turn 完了、subscriber 終了で必ず解決する。最初の応答者が await 前に ID 所有権を確定し、二重応答しない。transport 消失時だけ登録を破棄する。
- 停止は approval を Cancel で閉じてから interrupt。wire ID 不明や terminal event timeout は対象を推測せず共有接続を再起動する。
- projection overflow は対象 turn を停止し、raw routing overflow は承認を見失う可能性から接続を再起動する。thread subscription は lease で所有し、最後の解除と unsubscribe を新 owner の resume より後へ遅らせない。

## Vault MCP approval

固定 Codex の item ID のない MCP elicitation を避け、chat の `features.tool_call_mcp_elicitation=false` と `item/tool/requestUserInput` を使う。

許可するのは question 1件、item ID と `mcp_tool_call_approval_<itemId>` の一致、固定 header、非 secret / 非 other、既知の選択肢を満たし、同 turn の `item/started.mcpToolCall` が server `dahlia` と相関する場合だけ。server / tool / arguments 全体を表示できなければ許可しない。

snapshot は作成時20 KB以内とし、raw 巨大 arguments を cache に保持しない。bidi control は escaped 表示にする。今回だけの Allow を元 question ID へ返し、拒否・停止・overflow は Cancel。session / 永続許可は内部から渡されても Cancel にする。チャット本文の「承認」は tool gate への応答の代用にならない。

## 安全境界と経緯

要約・未知 thread、旧 v1 approval、未対応 request は fail-closed。`item/permissions/requestApproval`、grantRoot、追加 filesystem / network 権限を通常の承認 UI で付与しない。フルアクセスは別の明示タスク設定であり、approval UI が通常 sandbox を拡張するものではない。

初期の全 chat read-only と全要求拒否は、MCP write と skill 読込を成立させられなかった。全 provider のユーザー承認へ変更後、ChatGPT 代理承認を再導入し、最終的にタスク選択へ統合した。代理審査の追加モデル呼出と手動承認の操作量は選択に応じて残る。

Codex 更新時は approval schema、feature key、応答形式、早着・停止・二重応答・overflow を回帰確認する。UI の command / path / reason を log や Sentry に送らない。相関不能時の共有接続再起動は他の AI 操作にも影響し得る。
