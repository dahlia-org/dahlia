# Calendar event persistence schema

この文書は、カレンダー予定とMeetingをSQLiteおよび将来のDatabricks連携で同一に解釈するための永続化契約を定義する。

## 論理キー

`calendar_events` の主キーは `(ical_uid, recurrence_id)` である。

- `ical_uid`: iCalendar `UID`。前後の空白を除去し、空値は保存しない。
- `recurrence_id`: iCalendar `RECURRENCE-ID` の値をRFC 5545のbasic形式へ正規化した文字列。
  - 単発予定: `""`（Dahliaの規約。VEVENTにRECURRENCE-IDが存在しないことを表す）
  - DATE: `20260417`
  - UTC DATE-TIME: `20260417T003000Z`

DATEの値に`VALUE=DATE:`を付けない。`VALUE=DATE`はcontent lineのパラメータであり、`RECURRENCE-ID;VALUE=DATE:20260417`の値部分は`20260417`である。

繰り返し予定では、変更後の開始時刻ではなく元のoccurrenceを示す値を使う。Google Calendar APIの`originalStartTime`とEventKitの`occurrenceDate`をこの形式へ正規化する。

## テーブルとカーディナリティ

```text
calendar_events (ical_uid, recurrence_id)
    1 ─── 0..N calendar_event_sources
    1 ─── 0..N meetings

meetings
    1 ─── 0..N recording_sessions
    1 ─── 0..1 summaries
```

同じ予定に複数のMeetingを関連付けられる。各ユーザー・Vault・録音成果はMeetingとして分離し、文字起こし、録音セッション、サマリーもMeeting配下に保持する。

`meetings.calendar_event_ical_uid`と`meetings.calendar_event_recurrence_id`は、両方NULLまたは両方非NULLでなければならない。非NULLの場合は対応するcanonical eventが必要である。

## `calendar_events`

予定のcanonical情報を保持する。

| Column | Meaning |
|---|---|
| `ical_uid`, `recurrence_id` | 論理主キー |
| `title`, `description` | 予定の表示情報 |
| `start`, `end`, `is_all_day` | 現在観測している開催時刻 |
| `conference_uri` | Meet、Zoom、Teams、電話、SIPなどの参加先URI |
| `url` | Google Calendar Web UIなど、予定自体を参照するURL |
| `created_at`, `updated_at` | Dahliaでの初回・最終観測時刻 |

別ソースから同じキーを観測した場合、開催時刻などの基本情報は最新の観測で更新する。一方、空description、NULLの`conference_uri`、NULLの`url`は、他ソースで取得済みの有効値を消去しない。

## `calendar_event_sources`

provider固有の識別子をcanonical eventへ対応付ける。

主キーは `(platform, calendar_id, platform_id)`。`ical_uid`と`recurrence_id`は`calendar_events`を参照し、canonical eventの削除・キー更新に追従する。

`platform_id`だけではカレンダー間で一意とは限らないため、`calendar_id`を必ず含める。source行は、該当ソースから予定を観測して既存Meetingを解決した場合にもupsertする。

## ライフサイクル

- 新規Meeting作成時にcanonical eventとsourceをupsertしてからMeetingを関連付ける。
- 既存Meetingの解決時にも、最新のcanonical情報とsource mappingをupsertする。
- 最後の参照Meetingが削除された時点でcanonical eventを削除する。
- `calendar_event_sources`は外部キーのcascadeで削除する。
- 同じeventを参照するMeetingが残っている間はcanonical eventを削除しない。

## Databricks連携時の注意

- `calendar_events`は`ical_uid`単独ではなく、必ず`(ical_uid, recurrence_id)`でmergeする。
- `meetings.id`はUUIDv7であり、同一eventに複数値を許容する。
- source単位の重複排除には`(platform, calendar_id, platform_id)`を使う。
- `description`、`conference_uri`、`url`には機微情報が含まれ得るため、アクセス制御と削除伝播をMeetingデータと同じ水準で扱う。
