# 顧客インテリジェンス廃止とCalendar参加者スナップショット

対象: Desktop・Server。採択: 2026-09-11。

## 決定

顧客インテリジェンスのUI、設定、MCP、Codex preset、telemetryと、Contact、Organization、Insight、Topicおよび関連テーブルを廃止する。既存データは移行せず、新しいDesktop migrationで削除する。

Calendar参加者の自動取得は維持するが、人物identityやVaultとの関連を作らない。Desktopの`calendar_events.attendees_json`にemailとnullableな表示名をイベント単位で保存し、`meetings.calendar_event.attendees`としてServerへ同期する。人物だけを対象に、現在ユーザーを除外し、正規化emailで重複排除する。

wireで`attendees`を省略した更新は既存値を維持し、空配列は参加者を消去する。`calendarEvent: null`はスナップショット全体を消去する。暗号化Vaultでは`calendar_event`全体を`encrypted_payload`へ格納し、DB列をマスクする。

## 理由と結果

参加者は会議予定を理解するための観測値であり、Dahlia内の顧客マスタを必要としない。イベントのスナップショットに限定することで、Calendarからの有用な情報を保ちながら、VaultごとのContact identity、組織推定、関連グラフとその保守をなくす。

Server側のOrganizationとTeamは認証・共有管理の別概念として維持する。Projectsと会話分析もこの判断の対象外とする。廃止前の設計理由は[顧客情報の正準モデルと更新](../desktop/customer-intelligence.md)に履歴として残す。
