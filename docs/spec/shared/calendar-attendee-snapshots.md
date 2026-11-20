# Calendar 参加者スナップショットと顧客情報の廃止

対象: Desktop・Server。採択: 2026-09-11。

## 決定

顧客情報の正準モデル（顧客 Contact、顧客 Organization、Insight、Topic と関連テーブル、domain 共有と merge、UI、設定、MCP、Codex preset、telemetry）は廃止する。既存データは移行せず、Desktop の forward migration で削除する。

Calendar参加者の自動取得は維持するが、人物identityやWorkspaceとの関連を作らない。Desktopの`calendar_events.attendees_json`にemailとnullableな表示名をイベント単位で保存し、`meetings.calendar_event.attendees`としてServerへ同期する。人物だけを対象に、現在ユーザーを除外し、正規化 email（trim・小文字化・ASCII 検証を共通 RuntimeSupport で行う）で重複排除する。

wireで`attendees`を省略した更新は既存値を維持し、空配列は参加者を消去する。`calendarEvent: null`はスナップショット全体を消去する。暗号化Workspaceでは`calendar_event`全体を`encrypted_payload`へ格納し、DB列をマスクする。

参加者の取得は meeting 保存後に行い、録音では capture 成功後に行う。取得に失敗しても成功済みの meeting を rollback せず、録音開始を止めない。過去 meeting・全 calendar の自動 backfill はしない。

## 理由と結果

参加者は会議予定を理解するための観測値であり、Dahlia内の顧客マスタを必要としない。イベントのスナップショットに限定することで、Calendarからの有用な情報を保ちながら、Workspaceごとの Contact identity、組織推定、関連グラフとその保守を持たない。

Server側のOrganizationとTeamは認証・共有管理の別概念として維持する。Projectsと会話分析もこの判断の対象外とする。

## 移行と制約

- 廃止した顧客モデルのテーブル・データは移行せず、Desktop の forward migration で削除する。
- 未リリース QA schema の移行・整理履歴は、現在の migration 編集を許可する根拠として扱わない。schema の判断は機能仕様と実装を参照する。
- 顧客 Contact の identity を Workspace 横断の registry として持たず、名前補完もしない。

## 却下した案

- email を primary key にする: 元の記録に理由の記載はない。
- Workspace 横断の Contact registry: 元の記録に理由の記載はない。
- 汎用 entity / edge、永続的な graph 座標: 元の記録に理由の記載はない。
- sentiment や synthetic progress（Topic の進捗を保存値として持つこと）: 元の記録に理由の記載はない。Topic の状態は保存せず、参照履歴から導く設計だった。
- domain を単一の owner に一意に割り当てる方式: 別会社を誤統合したため、共有 domain を導入した。
- 独立した用語 store（Glossary）: 文字起こしや AI context を改善しなかったため。必要になれば、その入力として再検討する。

## 未適合・未検証

- 未確定: 削除 migration の Desktop 配布状況。本文は削除を要求するが、配布済みかどうかは記録がない。
- 未確定: 複数 email、一般的な merge / split、cloud-wide person identity は、別の設計判断を要する。
