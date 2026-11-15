# Pi 自己学習プランのレビュー

対象: [2026-11-15-pi-self-learning.md](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/docs/plans/2026-11-15-pi-self-learning.md)。役割は実装前の設計レビューであり、現行仕様や実装済み不具合の一覧ではない。
レビュー日: 2026-11-15。Dahlia の確認時 HEAD: `a68d6cc0c14445d3dc204c120888c0c6cb394bd7`。
状態: 静的レビュー完了。元のプラン・アプリコード・製品方針は変更していない。

このプランは、アカウント単位のメモリー、会話後のスキル改善、アプリが管理する定期実行を追加するもの。GRDB、既存のチャット実行、Pi 拡張を再利用する方向は妥当である。ただし、実行ごとの権限と変更の確定方法を補う必要がある。**P1 が 2 件、P2 が 6 件。実装前に下記をプランへ反映する。**

## 今回確定した前提

以下はユーザーの回答として扱い、未決事項や欠陥には数えない。

| 項目 | レビューの前提 | プラン改訂時の反映先 |
| --- | --- | --- |
| 定期実行の製品範囲 | 現在の範囲外規定を見直す予定。定期実行を検討対象から外す理由にしない | L18–19、L243–246、L283。採用する境界を ADR と製品文書に反映する。今回の回答だけで ADR の細部まで承認済みとは扱わない |
| Server Account のメモリー | 提案どおり Mac 内のアカウント別保存でよい | L284–285 を決定済みに移す。Server Memory との統合は今回不要 |
| 自動ふり返り | **既定 ON** | L169–171、L286。既存アカウントへの適用時点と停止時の扱いを定義する |
| アプリ終了中 | 実行しないことでよい | L203–204 を維持。終了中の動作やログイン項目の追加を今回の必須機能にしない |

「閉じていた間の分を再開時に 1 回処理する」は元の提案として維持して評価した。これは実行中だった処理の無条件再試行を認める意味ではない。

## 指摘事項

### R1 [P1] `readOnly` を積むだけでは、同じスレッドの対話権限を分離できない

**対象:** プラン L195–199、L232–234。ふり返りの起動境界は L145–149、L165–167。

**発生条件と影響:** 予定の結果スレッドをユーザーが開いて対話した後、同じ Pi プロセスが生きた状態で予定が発火する。現在の接続再利用条件はファイルアクセス設定だけなので、対話用に起動した `bash`・書き込み・スレッド操作などのツール構成を持ち越す。承認方式だけを `readOnly` にしても、これらは現在の MCP 承認分岐を通らない。逆に、制限したプロセスを対話へ再利用すると、対話に必要なツールが使えなくなる。

**一次根拠:** [接続の再利用条件](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService.swift:618)、[起動時のツール構成](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService.swift:702)、[ファイル操作とスレッド操作が MCP 承認より先に通る分岐](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/PiExtension/dahlia.ts:233)。また、現在の [Seatbelt](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/PiExtension/pi.sb:40) は作業フォルダ等にも書き込みを許し、スキル専用ではない。[sandbox の設定](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiRuntimeService.swift:868) も現在は chat モードにだけ適用される。

**最小修正:** 対話・定期実行・ふり返りの実行種別と許可内容をアプリが所有し、run の間は上限を固定する。接続を再利用する条件にツール・sandbox の構成を含め、不一致なら idle 時に開き直す。拡張の実行直前と Swift の bridge の両方で run の許可を確認し、`fullAccess` の UI 選択でも無人実行の上限を緩めない。ふり返りには既存 sandbox をそのまま使わず、必要なファイル操作にだけ限定した構成を用意する。

**完了条件:** 同じスレッドで「対話 → 定期実行 → 対話」を行い、権限が相互に持ち越されない。実行中の承認方式変更でも上限を超えず、ふり返りから作業フォルダや他アカウントのファイルを変更できない。

### R2 [P1] スキルの直接更新とフォルダ単位の巻き戻しが、別の変更を上書きする

**対象:** プラン L148–149、L160–167。

**発生条件と影響:** ふり返りがスキルを読んだ後、別の対話またはユーザーが同じファイルを更新する。ふり返りは元の内容に基づいて直接書けるため、その更新を上書きできる。また、ふり返り前に採ったフォルダの複製だけでは、並行した対話の変更まで自動学習の変更として記録しうる。その複製へ戻すと、自動学習の後に行った無関係な変更も消せる。アカウント内のふり返りを 1 本にしても、対話との競合は防げない。

**一次根拠:** プラン自身が最大 3 本の対話との並行を想定する一方、履歴は実行前の `pi/skills/` 全体だけで、反映前の版照合も変更ごとの owner も定義していない。[T1](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/PRODUCT.md:37) は人が確定した値の保護と取り消しを求める。比較元の [Hermes の無人ふり返り] も、通常のファイル書き込みを禁止し、検証付きの `skill_manage` を通している。

**最小修正:** 自動ふり返りは実ファイルを直接更新せず、作業コピーへ変更を作る。アプリが変更したファイルだけを検証し、読み取り時の hash と一致するものだけ反映する。不一致なら上書きせず保留する。履歴は反映した変更の前後を保持し、取り消し時にも現在値と変更後の hash を照合する。対話中の手動指示による直接編集は今回維持できるが、自動反映側の競合検出は必須。

**完了条件:** ふり返り中の別対話による同一ファイル更新が失われない。取り消しで別スキルや後続の編集が消えない。不正な SKILL.md や適用途中の失敗は、利用中のスキルを壊さない。

### R3 [P2] スレッドの除外だけでは、外部データからの自動学習を防げない

**対象:** プラン L131、L142–153、L161。

**発生条件と影響:** ユーザー起点の通常の対話で Slack、Gmail、会議、別スレッドを読む。その後のふり返りは、そのツール結果を含む履歴を受け取り、「ツールの結果に根拠があるもの」も保存できる。定期実行・子スレッドを除外しても、この入力経路は残る。外部本文にある依頼・推測を本人の好みやスキルの指示として保存すると、次回以降の対話へ持ち越す。会議や DB の内容は保存しないという L131 の方針とも衝突する。

**一次根拠:** [通常の対話へのツール結果の保存](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService.swift:877)、[機械からの依頼を user の許可と分ける既存契約](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/docs/adr/desktop/chat-thread-orchestration.md:33)、[MCP の結果を指示として実行しない契約](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/docs/adr/desktop/agent-mcp-operations.md:26)。文字列パターンの検査だけでは入力の由来は区別できない。

**最小修正:** 学習の適格性を thread 単位だけでなく run / Item の由来で判断する。人物像・好みの自動保存は、本人が直接述べた継続的な発言や訂正を根拠とする。ツールの入出力はスキル改善の成否を調べる資料として区別し、そこに含まれる命令へ権限を与えない。保存候補に根拠となる Item を紐付け、不確かな候補は反映しない。

**完了条件:** 外部本文や機械の依頼にだけ含まれる好み・指示が保存されず、同じ内容を本人が明示した場合は学習できる。外部データを扱った通常の対話も検証対象に含める。

### R4 [P2] ふり返りを、正本の確定した範囲に結び付けていない

**対象:** プラン L136–147。

**発生条件と影響:** 予約の後に新しい対話が始まり、10 分の期限を越えて実行が続く。予約を後ろへずらすのは次の実行が「終わる」時なので、その途中で元のふり返りが発火できる。追記中の Pi ファイルを複製する時点と `chat_items.seq` の対応がなく、`reviewedThroughSeq` をどこまで進めるべきか決められない。完了時の最新 seq まで進めると未読の発言を飛ばし、ファイル全体を毎回学習対象にすると処理済みの内容を繰り返し学習する。

**一次根拠:** 「`chat_items` にツールの入出力が残らない」という L147 の前提は現行コードと異なる。[ChatHistoryCodec](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/ChatHistoryCodec.swift:73) は `tool_call` と `tool_result` を保存し、個別 payload を 65,536 bytes で明示的に切り詰める。[保存経路](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService.swift:826) も存在する。[ARCHITECTURE](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/ARCHITECTURE.md:311) では正本は GRDB、Pi ファイルは再開状態である。

**最小修正:** 開始時にスレッドが idle かを確認し、同じ DB snapshot で `reviewedThroughSeq < seq <= capturedThroughSeq` を確定する。GRDB の message / tool Item を主入力とし、過去の文脈が必要なら処理済みと分かる形で限定的に補う。切り詰められた結果は不完全な証拠とする。Pi ファイルが必要な情報を具体的に特定できた場合だけ補助入力にする。正常終了後に capturedThroughSeq まで進め、失敗・中断と変更済み状態の再試行を区別する。

**完了条件:** 長い対話の途中では開始しない。ふり返り中に追加された発言は次回に残る。Pi の再開ファイルがなくても、保存済みの範囲をレビューできる。再試行で同じ変更・通知を重複反映しない。

### R5 [P2] 選択していないアカウントの予定が、既存経路では失敗または中断になる

**対象:** プラン L191–196、L256。

**発生条件と影響:** Server Account A の予定時刻に、ユーザーが Local Account B を開いている。プランは accountID を持つ予定を既存の送信経路へ積むが、現行 Pi は選択中アカウントしか動かさない。A の待機 run は中断されるか、接続時に拒否される。予定だけ次回へ進めると、A の確認を行わないまま実施時刻を通過する。

**一次根拠:** [実行時のアカウント不一致で待機 run を中断する処理](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService+Orchestration.swift:39)、[アカウント切替で旧実行を停止する処理](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService+Subscriptions.swift:122)、[起動時の provider 検証](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiRuntimeService.swift:94)。

**最小修正:** 今回は選択中アカウントだけを動かす契約を維持し、非選択アカウントの期限到来は未実行として保留する。そのアカウントに戻った時に 1 回へ集約し、画面に待機理由を出す。ふり返りにも同じ境界を適用する。全アカウント同時実行へ変える場合は別の明示的な設計変更にする。

**完了条件:** A の予定中に B へ切り替えても B のデータや認証では実行されず、A に戻ると保留分が 1 回だけ動く。

### R6 [P2] 予定の発火と run 登録の間に、重複・取りこぼしを防ぐ永続契約がない

**対象:** プラン L191–203。

**発生条件と影響:** 予定の run 登録後、次回時刻の更新前にアプリが終了する。背景ジョブが再試行すれば同じ発火分を再登録できる。逆の順序では、run を残さず次回へ進みうる。また、予定の run が対話や長い確認を待っている間も次の発火を登録し続けると、古い確認の待機列が積み上がる。「停止中の分は 1 回だけ」という方針は、既存の背景ジョブを置くだけでは成立しない。

**一次根拠:** [既存の enqueueRun](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/ChatThreadStore+Runs.swift:17) の重複排除は依頼元 thread・root run・clientRequestID の組であり、予定の発火単位を扱わない。[再起動時の復旧](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/ChatThreadStore.swift:130) は queued も interrupted にする。背景ジョブの再試行とチャットの復旧は同じ契約ではない。

**最小修正:** 発火を識別する安定したキーを持ち、run の登録・発火記録・次回時刻の更新を同じ transaction で行う。予定ごとの未開始分は 1 件に集約する。再起動時には未開始・開始済みを区別し、開始済み run の無条件再試行は既存契約どおり行わない。何を実施済みとするかを `lastRunAt` だけに兼務させない。

**完了条件:** transaction の前後で終了を挟んでも同じ発火分を二重登録しない。長い対話中に複数回期限が来ても未開始分は最大 1 件。再起動後に中断した run と保留中の予定を区別して表示できる。

### R7 [P2] 有効な予定を変更した時の再確認と、古い run の無効化が抜けている

**対象:** プラン L177、L191–192、L209–214。

**発生条件と影響:** ユーザーが内容を確認して有効化した予定を、後の対話で `dahlia_schedule` が更新する。確認を必須にする操作は「作成と有効化」だけなので、enabled のまま prompt・頻度・許可ツールを変えると、新しい内容を本人が見ずに無人実行できる。既に積まれた run に古い prompt が入っている場合、予定の修正や無効化の後もそれが開始できる。

**一次根拠:** プランは更新ツールを公開する一方、承認した版や許可ツールの保存先を定義していない。[既存の実行](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService+Orchestration.swift:47) は保存された run.input を使い、開始前には queued 状態を確認するが、親となる予定の enabled や revision は確認しない。

**最小修正:** 承認対象を prompt・時刻・許可内容の組とし、予定に revision を持たせる。有効な予定の実行内容を変える場合は変更後を再確認し、run は承認済み revision に結び付ける。無効化・削除・更新時には古い未開始 run を無効化する。開始済みも停止する操作なのか、次回以降を止める操作なのかを UI で明示する。

**完了条件:** enabled のまま内容を変えても無確認で反映されない。待機中に無効化・変更した予定から古い内容が開始しない。

### R8 [P2] 定期実行の root run は、現在の「3 本」制限に数えられない

**対象:** プラン L39、L183、L195–196。

**発生条件と影響:** 同じアカウントで 4 件以上の予定が同時に期限を迎える。予定はユーザー送信を起点にせず、それぞれ独立した root run になる。現在の待機列が 3 本の上限に数えるのは `rootRunID != id` の実行だけなので、この形式の定期実行は何本動いてもカウントされない。既存経路の再利用だけでは、プランが前提とする上限を守れない。

**一次根拠:** [scheduleRuns の active 計数](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService+Orchestration.swift:23) と [通常の root run 作成](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService.swift:434)。現状は人の送信を待機列の制限から外すための判定であり、予定はまだ存在しない。

**最小修正:** 実行の起点を永続化し、人の入力・スレッドからの依頼・定期実行を区別する。定期実行と依頼された実行を、アカウントの無人実行上限へ数える。人の送信が待機列を待たない現在の契約は維持する。ふり返りの別枠 1 本との合計も明記する。

**完了条件:** 4 件以上の予定を同時に発火させても無人実行は上限内に収まり、ユーザーの送信はその待機列に阻まれない。

## 調査記述の訂正

以下は欠陥件数に追加せず、改訂時に前提を修正する事項。

1. **Hermes の無人更新の保護を補う。** 調査時と同じ commit `fd8a6c41ace59b476193c61002ce6a86d667b18a` を保存済み checkout で確認した。[memory_tool.py の無人変更ゲート] は `patch` / `remove` 等を直ちに適用せず承認待ちへ送る。[無人ふり返り] はファイルの汎用書き込みを拒否して `skill_manage` に通す。プラン L55–57 だけではこの差が読めず、L165–167 の「保存先を制限できれば専用の反映経路は不要」という根拠にはならない。Dahlia が同じ UI を移植する必要はないが、R2 の競合検出・検証・復元に相当する保護は残す。
2. **`suppressAutomaticNotification` は未読や macOS 通知を抑止する汎用フラグではない。** [利用箇所](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService+Orchestration.swift:80) は依頼元 thread への結果配達・自動再開を止める処理である。プラン L200 の機能にはそのまま使えない。L273 の事前確認と合わせ、定期実行の結果をどう表示・通知し、どこで `[SILENT]` を解釈するかを決める。通知機能が未実行であること自体を欠陥とはしていない。
3. **ツール履歴は保存されているが、無制限の原文ではない。** R4 のとおり、保存の有無と全文性を分ける。履歴検索の対象外であることも、DB に保存されないことを意味しない。

## 元の設計質問への判断

| 論点 | 判断 |
| --- | --- |
| cron の owner | アプリ側でよい。認証・アカウント・永続待機列を既に持つ。ただし R5・R6・R8 の既存契約との差分が必要 |
| 定期実行の `bash` 除外 | 初期段階は妥当。`readOnlyHint` はツール提供元の申告なので、任意の MCP に対する情報持ち出し防止の保証とは表現しない。予定ごとに確認した接続先・ツールの範囲を記録する |
| GRDB のメモリー | 妥当。人が編集した行の保護とアカウント分離に合う。日本語での上限やトークン量は試用で調整する対象で、現時点の欠陥にはしない |
| 10 分の静穏時間・3 発言の下限 | 10 分は開始値としてよい。下限 3 件だと単発の明確な訂正も保存しないため、明示的な「覚えて」や訂正を対話中の memory ツールで保存できることを受入条件にする |
| 予定 1 件に Thread 1 件 | 閲覧用のまとまりとして妥当。Pi プロセスの権限を共通にする理由にはせず、R1 の切替を行う。文脈に前回結果が残るだけでは差分確認の完全性は保証しない |
| 対話中のスキル履歴 | 自動学習の導入に伴って全対話の履歴管理まで拡張する必要はない。ただし、それらを R2 の巻き戻しへ巻き込まないことが条件 |
| Server Memory の方針との関係 | Mac 内の会話からの学習と Server の整理ジョブは実装範囲が異なる。保存済みメモリーの自動削除・統合まで「会話からの保存」に含めず、新しい Desktop ADR で境界を明記する |

既定 ON は今回の決定として採用する。設定で OFF にしたときは新しい予約を止めるだけでなく、待機中・実行中のふり返りと反映直前の変更をどう止めるかを定義する。メモリー全体の OFF とふり返りだけの OFF も区別する。これは OFF を初期値に戻す提案ではない。

## 改訂と検証の順序

1. 今回の決定をプランに反映し、run の起点・権限・アカウント・予定の revision を定義する（R1・R3・R5・R7・R8）。
2. 学習入力の確定範囲と、スキルの検証・競合検出・巻き戻しを定義する（R2・R4）。
3. 予定の発火 transaction、未開始分の集約、中断時の状態を定義する（R6）。
4. 上記の完了条件を、使い捨て DB・fake Pi transport・隔離した sandbox ファイルで検証する計画へ追加する。その後、実 Pi の起動・ツール制限・セッション再開を少数の実機確認で確かめる。

元の「事前に確かめること」は未確認事項として維持する。Slack / Gmail MCP の実在・権限・`readOnlyHint`、実モデルの品質・費用、Pi の再開時の挙動、通知の実表示は今回動作確認していない。Hermes の LICENSE は上記固定 checkout で MIT を確認したが、コードや検査パターンを実際に移植するときの表示対応は実装側で確認する。

今回実施したのは、プラン全体と関連する Dahlia のコード・設計契約、Hermes の固定コミットの静的照合である。アプリ、モデル、Slack、Gmail は実行していない。Swift の変更がないため build / test / lint は実行していない。

[Hermes の無人ふり返り]: https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/background_review.py#L1192-L1218
[無人ふり返り]: https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/background_review.py#L1192-L1218
[memory_tool.py の無人変更ゲート]: https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/tools/memory_tool.py#L179-L212
