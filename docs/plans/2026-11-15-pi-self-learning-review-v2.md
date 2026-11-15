# Pi 自己学習プラン 第2版の再レビュー

対象: [プラン第2版](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/docs/plans/2026-11-15-pi-self-learning.md)。レビュー日: 2026-11-15。
役割: 実装前の再レビュー。元のプラン・前回レビュー・アプリコードは変更していない。
対象の SHA-256: `1bf3672e7252305479471cee1ecfc71082ab58b662927e5616ff5768120ff4f1`。
Dahlia HEAD: `a68d6cc0c14445d3dc204c120888c0c6cb394bd7`。Hermes 比較元: `fd8a6c41ace59b476193c61002ce6a86d667b18a`。

第2版は、実行の権限・アカウント・変更履歴をアプリが所有する方向に改善している。一方、学習の中身は Hermes の同等移植から独自設計へ広がっている。**今回の指示に合わせ、Hermes のプロンプト・ツール契約・学習の発火条件・更新時の保護を基線に戻すべきである。** 技術上も P1 が2件、P2 が4件残る。

## 今回の採用基準

1. Hermes の原文と実行時の保護を先に移す。短い要約に書き換えたり、別のメモリーモデルへ置き換えたりしてから評価しない。
2. Swift / GRDB / Pi への接続、アカウント境界、録音優先など、Dahlia に組み込むための変更は行う。移植元の実装言語や常駐 gateway まで複製する必要はない。
3. 意味が変わる箇所には、Hermes の挙動・変更理由・代替する保護・確認方法を記載する。技術的に必要な差分と、将来の拡張案を分ける。
4. 「先行実装を尊重する」は不具合まで再現する意味ではない。確認できた問題は最小限に修正する。ただし issue の題名だけを根拠に学習ループ全体を別方式へ変えない。

利用者が確定した、Mac 内のアカウント別保存、ふり返り既定 ON、アプリ終了中は実行しない、定期実行の製品範囲を見直す、の4点は維持する。

## Hermes と同じものを先に作るための修正

次は一般的な好みの指摘ではなく、今回の移植方針に対する差分である。技術指摘の件数とは分ける。

| 項目・プランの場所 | Hermes の基線 | 次版での対応 |
| --- | --- | --- |
| 2段メモリー・5型・検索、L18–20 / L135–160 | `USER.md` と `MEMORY.md` に相当する2領域。既定上限はそれぞれ1,375字と2,200字。両方の開始時 snapshot をプロンプトへ入れ、`target` と `operations[]` の add / patch / remove を使う [H2] | 初版はこの契約を移す。保存先は GRDB でよい。5型、検索前提、2,000件への拡張は後にする。「20社なら1〜2週間で埋まる」は今回実測されておらず、この変更の根拠にしない |
| ふり返りの指示、L203–211 | メモリー専用・スキル専用・両方の3プロンプトと共有ブロックがある。スキルは積極的に改善し、読み込み済みのスキルを優先する。好みをメモリーとスキルへ重複保存しない [H1] | 原文を移植元として管理し、まず英文のまま使う。変更はツール名・保存先・Dahlia 固有の変更不可領域などに限定し、差分を残す。「要旨を自分たちの言葉で書く」をやめる |
| 発火条件、L179–189 | メモリーは user turn、スキルは tool-calling iteration の別カウンター。各閾値に達した時だけ対応するレビューを選ぶ。固定コミットのコード上の fallback は10 / 10 [H3] | 10分静かになったら毎回まとめてレビューする方式を初期仕様にしない。同じカウンターとレビュー範囲を先に移す。録音中・非選択アカウントでの保留はアプリ側の追加制約として残す |
| ふり返りの入力とモデル、L191–200 / L218 | 同じモデルへの fork は会話 snapshot と system prompt・tools・reasoning 設定の prefix を保つ。実行可能なツールは dispatch 側で絞る。別モデルへ route した場合は digest を使う [H4] | Pi で再現できる境界を事前確認する。GRDB を正本とする点は維持できるが、増分 Item だけを渡すことや reasoning の low 固定を「同じモデルだから同等」と扱わない。F4 も参照 |
| 学習の実行上限、L197–201 / L356 | 固定コミットには1回16 iteration の上限と、レビュー全体の入力 token 予算がある [H4] | 同じ制限の役割を移す。入力が大きければ事前に考える、だけで終えず、上限到達時の終了・未処理範囲・再試行の扱いを決める。数値を変える場合は理由を残す |
| スキルの更新、L84–85 / L119–121 / L198–200 | `skills_list` / `skill_view` / `skill_manage`。fresh read、変更の排他、検証、失敗時の復元、変更履歴を管理経路に集める [H5] | 汎用 write / edit と最終 diff の走査を先に作るのではなく、このツール契約を Pi の薄い adapter で再現する。作業コピーを内部実装に使うことは可能。F2 を満たす共通の反映経路が必要 |
| cron の実行文脈、L281–282 | 発火ごとに新しい session。継続性が必要なら、前回の非静音結果などを明示的な context として加えられる。cron の実行指示も専用の原文がある [H6] | 結果表示の Thread は予定ごとにまとめてもよいが、Pi の実行文脈は毎回新しくする。必要な前回結果だけを明示的に渡し、対話と全履歴を自動共有しない。静音の判定も原文・実装の例に合わせる |
| 将来イベント用の汎用化、L245–250 / L391–396 | 今回必要なのは定期実行であり、会議イベントは依頼された初版の必須機能ではない | 初版の契約を時刻による schedule に絞る。表名の好みは問わないが、会議イベントを想定した抽象化を採用理由にしない。イベント実行は同等移植を使ってから判断する |

特に、Hermes のスキルプロンプトは約9,000字あり、単なる「根拠のある教訓を保存する」ではない。既存スキルへの改善を優先する順序、好みの埋め込み先、補助ファイルの役割、fresh read の強制、未解決の失敗を手順として残さない規則が一体になっている。これらを短く書き直すこと自体が、挙動を変える変更になる。

原文の移植では、MIT の copyright / license notice を保持する。ツールの別名が必要なら名前を adapter で対応付け、プロンプトの意味をまとめ直す理由にしない。

## 技術上の指摘

以下は第2版を静的に読んで確認した設計上の欠落であり、未実装の機能を実環境で再現したという意味ではない。

### F1 [P1] 無人のメモリー変更・削除が、Hermes の承認待ちを迂回する

**場所:** プラン L113–118。

**発生条件・影響:** 過去の自動学習で保存した行を、後のふり返りが変更または削除する。第2版は「自分で足した行」で根拠が人の発言なら自動反映するため、ユーザーが明示的に管理していない既存の知識を無人で置き換えられる。後から取り消せることは、反映前に既存値を保持する承認待ちと同じ保護ではない。

**一次根拠:** Hermes の `_background_delete_gate` は、無人ふり返りの patch / remove 等を、保存した主体にかかわらず pending に送る [H2]。第2版の L64–65 はこの保護を引用しているが、反映表では緩めている。

**最小修正:** 無人では add のみを直接適用し、変更・削除は対象の版を固定した承認待ちへ送る。対話で本人が明示的に変更を頼んだ処理と区別する。`protected` の保護は別途維持する。

**確認条件:** 自動保存した行にも protected の行にも、無人 patch / remove は直ちに反映されない。承認前の競合では上書きせず、pending の保存失敗時も既存行を残す。

### F2 [P1] ハッシュ照合だけでは、並行するスキル編集を保護できない

**場所:** プラン L119–120、L127–131、L198–200。前回 R2 の未解消部分。

**発生条件・影響:** アプリが現在値と baseHash の一致を確認した直後、対話側の write / edit が同じファイルを更新する。その後にアプリが作業コピーを反映すると、対話の変更を上書きする。取り消しも同じ競合を持つ。第2版は対話の直接編集を維持しているため、反映側だけを直列化しても防げない。

**一次根拠:** [現在のファイル書き込みツール](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/PiExtension/dahlia.ts:219) は Pi の各プロセスから独立して書く。Hermes は1つの skill に対する guard・read-modify-write・ledger capture・atomic replacement を同じ排他区間へ入れる [H5]。

**最小修正:** Hermes の skill 管理経路を参考に、Dahlia が制御する全てのスキル変更と取り消しを同じ排他へ参加させる。ハッシュ再確認から反映までをその区間に含める。対話の汎用 write / edit / bash で実物へ書く経路を残すなら、それらにも同じ調停が必要である。外部エディタまで同じ排他に参加させられるとは主張せず、外部変更検出の限界は分ける。

**確認条件:** hash を確認した後、反映直前へ別の Pi の編集を差し込む試験で更新が消えない。取り消しにも同じ試験を行う。通常の「読んだ後、hash 確認より前に変更した」試験だけでは不十分。

### F3 [P2] Item と run の所属関係を保存しないと、由来を検証できない

**場所:** プラン L73–79、L123、L191–195。

**発生条件・影響:** 同じ Thread に user / thread / trigger 起点の実行が混在する。第2版は Item がどの origin の実行に属するかをアプリが検証するとしているが、追加する列は chat_runs 側だけである。既存の保存形式からは、その所属を後で確実に復元できない。機械の依頼も Pi には user role で渡るため、role や文面からの推測に戻ると除外条件が崩れる。

**一次根拠:** [ChatItemRecord](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Database/ChatItemRecord.swift:17) は id / threadID / seq / data / createdAt のみ。[Item の作成](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/PiChatService.swift:434) と [応答の保存](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/ChatThreadStore+Runs.swift:50) にも Item 側の runID 保存はない。

**最小修正:** Item に信頼できる runID または同等の所属情報を永続化する。通常入力、steer、tool 結果、結果通知による自動再開を含める。モデルが書く evidence の自己申告をそのまま信頼せず、account / thread / 確定範囲との一致をアプリが確認する。移行前の由来不明 Item は自動学習対象にしない。

**確認条件:** 1つの Thread で3種類の起点と自動結果通知を混ぜても、それぞれの所属を保存内容だけから判定できる。user role の機械入力を本人発言と誤認しない。

### F4 [P2] ふり返りへ増分だけを渡すと、訂正や成功に至った経緯が欠ける

**場所:** プラン L191–195。前回 R4 は範囲の確定を改善したが、入力の意味が不足している。

**発生条件・影響:** ある手順の失敗と調査が前回レビューまでにあり、その後にユーザーが「この方法で通った。今後もこれで」と訂正する。新しい範囲だけでは「この方法」の参照先や、失敗から成功までの手順が含まれない。スキル改善に必要な比較対象や、どのスキルを使っていたかを失い、保存を見送るか誤った手順を一般化する構成になる。

**一次根拠:** 第2版の review profile は会話検索ツールを提供せず、渡す入力も増分に限る。Hermes は同一モデルでは full snapshot、別モデルでは過去の digest と直近の文脈を渡し、読み込んでいたスキルの改善を優先する [H1] [H4]。

**最小修正:** 「どこまで新たにレビューしたか」と「判断に必要な文脈」を分ける。Hermes と同等の会話 snapshot を基本とし、GRDB から再構成する場合も処理済みの文脈を含める。checkpoint は再処理の判定に使い、過去の関連文脈を切り捨てる境界にしない。モデルを替える場合の digest も原文の役割に合わせる。

**確認条件:** レビュー境界をまたぐ失敗→修正→成功、指示の訂正、読み込み済みスキルへの追記を扱える。既に処理済みの文脈を渡しても同じメモリーや通知を重複作成しない。

### F5 [P2] 未開始の予定 run が再起動時に失われる経路が残る

**場所:** プラン L257–269。前回 R6 の未解消部分。

**発生条件・影響:** 発火 transaction が run を queued で登録して nextFireAt を進めた後、実行枠を待っている間にアプリが終了する。現行の復旧処理は queued も interrupted にする。第2版は「始まっていた実行」を再実行しないとだけ定めており、未開始分を戻す規則がない。発火記録は残っているため、同じ fireKey の再登録も何もせず終わり、その回の確認を行えない。

**一次根拠:** [recoverInterruptedThreads](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/ChatThreadStore.swift:130) は queued / running / waitingForUser を一括して interrupted にする。発火 transaction の原子性だけでは、別途行われる起動時復旧との差を埋められない。

**最小修正:** trigger 起点の未開始分について、fire と run の復旧を定義する。起動時に enabled・承認した revision・所属アカウントを再確認し、未開始だけを最大1件へ戻す。開始済みは従来どおり自動再試行しない。通常の対話・委譲 run の復旧規則を一括で緩めない。

**確認条件:** 発火登録後かつ開始前に終了して再起動しても、未開始分は1回実行される。既に開始していた分は自動再実行されず、無効化・改訂された古い予定も再開しない。

### F6 [P2] 静音結果を永続的に区別する状態がなく、未読の印が復活する

**場所:** プラン L284–289。

**発生条件・影響:** 最後に見た seq より後に静音結果が保存される。endRun でその場の印・通知を出さなくても、Thread を再読込した時には「結果の seq > 最後に見た seq」が再び成立する。静音だったことを保存しないと、再起動後の未読表示を正しく再構成できない。最後に見た seq を静音結果まで勝手に進める方法では、その前にある通常の未読結果を消してしまう。

**一次根拠:** 第2版が追加するとしている状態は最後に見た seq であり、run / result に静音かどうかの永続状態を定義していない。[既存の結果保存](/Users/kazuki.matsuda/.t3/worktrees/dahlia/t3-f1f1b73b-8a539007750c2420/apps/macos/Sources/Dahlia/Services/ChatThreadStore+Runs.swift:50) も、通知可能な結果の seq を別に持たない。Hermes の静音判定にも、単なる先頭行判定より広い明示的な契約がある [H6]。

**最小修正:** 静音判定を result / run に保存するか、通知対象となった最後の結果 seq を別に保存し、最後にユーザーが見た seq と比較する。既に計画にある `chat_trigger_fires.status` を使うなら、静音結果との対応と照合方法を明記すればよい。ユーザーの閲覧位置を静音処理で書き換えない。`[SILENT]` の解釈は Hermes の matcher のケースを移し、通知投影を再構成しても同じ結果になるようにする。

**確認条件:** 静音結果だけなら、再読込・再起動後も印が出ない。通常の未読結果の後に静音結果があっても、前者の印は残る。本文中でトークンを引用した通常の報告は失われない。

## 前回レビューの解消状況と訂正

| 前回 | 第2版の評価 |
| --- | --- |
| R1 権限の持ち越し | profile による起動・再利用・実行直前の制約を計画へ反映。方向は妥当。実装・実機での成立は未確認 |
| R2 スキルの競合・取り消し | ファイルごとの変更記録は改善したが、排他がない。F2 として未解消 |
| R3 外部データからの学習 | 由来を区別する方向は妥当だが、所属情報の保存が不足する。F3。本人発言だけへ一律限定した前回の提案は下記のとおり訂正 |
| R4 入力と checkpoint | GRDB の snapshot と上限 seq は改善。判断に必要な文脈が不足するため F4 を追加 |
| R5 非選択アカウント | 保留して選択時に動かす契約を反映。方向は妥当 |
| R6 重複・取りこぼし | 同一 transaction と発火キーは改善。起動時の queued 復旧が未定義で F5 |
| R7 予定の改訂 | revision・再確認・未開始分の無効化を反映。方向は妥当 |
| R8 同時実行の計数 | origin による計数を反映。方向は妥当 |

**前回レビューへの訂正:** 「メモリーは本人発言だけを根拠にする」を全領域へ一律に当てる提案は広すぎた。Hermes は、USER の継続的な好みを推測せず、MEMORY の環境・ツールの事実は確認した tool result も根拠にできる [H1]。外部の命令を実行しないことと、ツールで確認した事実を一切学ばないことは別である。Dahlia の会議本文を自動複製しない制約は残しつつ、この区別を移す。

また、「何もしない割合」の評価をスキルにも一律適用しない。Hermes はメモリーには慎重な保存を求め、スキルには訂正や再利用できる成功手順があれば積極的な更新を求める。第2版の30会話は捨てる必要はないが、memory と skill の期待値を分け、移植元の規則に対応するケースへ組み替える。

## 次版に残すもの・後へ回すもの

残すのは、アプリ側の schedule、GRDB による耐久性、アカウント境界、origin / profile、録音を優先する保留、予定の改訂確認、必要な変更履歴と取り消しである。これらは Hermes の知見を置き換えるものではなく、Dahlia の runtime に接続するために必要になる。

後へ回すのは、検索型の大きなメモリー、5型への分類、会議イベントを見越した汎用化、取り消し率を主指標にする設定画面の追加である。まず同等移植を使い、足りない点を具体的な会話・費用・失敗例で確認してから変える。

同梱・パッケージのスキルを直接変更しない既存の Dahlia 契約も維持する。Hermes の「読み込んだスキルから改善する」を組み込む際、この部分はアカウント側への別名カスタマイズとして扱うなど、必要な適応として明記する。

## 移植元の確認先

全て上記固定コミットの保存済み checkout を静的に確認したもの。GitHub の最新 HEAD や、実際の起動時設定を確認したという意味ではない。

| ID | 原文・実装 | 確認した役割 |
| --- | --- | --- |
| H1 | [background_review.py:441–656](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/background_review.py#L441-L656) | 3プロンプト、領域の区別、重複防止、積極的なスキル更新、fresh read |
| H2 | [memory_tool.py:179–216](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/tools/memory_tool.py#L179-L216)、[同ツールの schema](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/tools/memory_tool.py#L366-L432)、[MemoryStore](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/tools/memory_tool_store.py#L177-L200) | 無人変更の承認待ち、2つの target、原子的な operations、既定上限と開始時 snapshot |
| H3 | [review_signals.py](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/review_signals.py#L1-L64)、[メモリーの既定値](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/agent_init.py#L1193-L1197)、[スキルの既定値](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/agent_init.py#L1233-L1237) | user turn と tool iteration を別に数える。cron・委譲の除外。設定例の skill interval は15だが、コードの fallback は10であり区別が必要 |
| H4 | [fork とモデル設定](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/background_review.py#L922-L1137)、[dispatch 制限と会話入力](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/background_review.py#L1265-L1311)、[予算](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/agent/background_review.py#L246-L301) | 親の provider / model / reasoning・prompt / tool schema の継承、別モデル時の digest、16 iteration と全入力予算 |
| H5 | [skill の排他](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/tools/skill_manager_tool.py#L98-L118)、[変更処理の所有区間](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/tools/skill_manager_tool.py#L810-L845)、[検証と復元](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/tools/skill_manager_tool.py#L421-L446)、[無人の保護](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/tools/skill_manager_guards.py#L166-L250) | 共通の更新ロック、fresh read、検証失敗時の復元、削除・ユーザーロックの保護 |
| H6 | [発火ごとの session ID](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/cron/scheduler.py#L2567-L2576)、[前回結果の context](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/cron/scheduler_prompt.py#L56-L64)、[cron 専用指示](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/cron/scheduler_prompt.py#L270-L289)、[静音判定](https://github.com/NousResearch/hermes-agent/blob/fd8a6c41ace59b476193c61002ce6a86d667b18a/cron/scheduler.py#L563-L575) | 毎回新しい実行、明示的な継続情報、自動配信・再帰禁止、静音の扱い |

原文を後から照合できるよう、Python の import やモデル実行をせず AST の文字列定数を連結し、3プロンプトの SHA-256 を算出した。ツール名等を適応した後のハッシュではなく、固定コミットの元の文字列のハッシュである。

| 定数 | 字数 | SHA-256 |
| --- | --- | --- |
| `_MEMORY_REVIEW_PROMPT` | 1,477 | `b5ceb4e4b14d61e4f27ce084b595813c32ced62cb431bc26067c6ec3096f03a2` |
| `_SKILL_REVIEW_PROMPT` | 9,186 | `34339ea685172e604be30e369cdd6fb313b4bbcb34bd5e9bd058d9eebd282038` |
| `_COMBINED_REVIEW_PROMPT` | 8,687 | `3582eec1d1736d8501ba99122ad257595328a56fcff477db9d74e8d7163b9c7a` |

未確認: Pi での fork / cache の同等性、実モデルでの学習品質と費用、Slack / Gmail MCP の利用可否、実機の sandbox・通知・再起動時の挙動。Hermes の issue 本文と全サブシステムは再調査していない。コード変更がないため Swift build / test / lint は実行していない。
