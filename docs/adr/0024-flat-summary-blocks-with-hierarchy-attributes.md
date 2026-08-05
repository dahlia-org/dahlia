# ADR-0024: 平坦な block 列に階層属性を持たせてネストリストと table を表現する

## Status

Proposed; amends 0001 and 0018

## Date

2026-08-05

## Context

ADR-0001 が定めた現行のサマリー構造化フォーマットは、見出しが実質 3 層 (title = H1 / `section.heading` = H2 /
heading block は level を 3 以上に clamp) で、`sections` は再帰しない。この平坦さは strict structured output の
安定生成と 5 系統のレンダラ実装を簡潔にしてきた一方、次の表現が不可能である。

- ネストした箇条書き・番号付きリスト・チェックリスト。LLM が会議の親子関係 (議題 → 論点 → 詳細) を
  出力しようとしても、すべて同じ深さに潰れる。
- LLM 出力での表。AST には `table` block が存在するが、ADR-0001 が LLM schema から除外したため、
  生成経路では使われない。
- 引用の内側に置くリストやコードなどの block。

実装の現状は以下のとおりである。

- DTO: [`SummaryDocumentResponse`](../../Sources/Dahlia/Models/SummaryDocumentResponse.swift) は
  単一 object + `type` discriminator 8 種で、`anyOf` を使わず、未使用 field も空文字・空配列・0 として
  required にする。`table` は LLM schema に含まれない。
- 正準 AST: [`SummaryDocument`](../../Sources/DahliaRuntimeSupport/SummaryDocument.swift) は
  `schemaVersion = 3`、`SummaryBlockContent` は `table` を含む 9 種。未知の `type` は paragraph へ
  フォールバックし、`id` を持たない block は coding path から FNV-1a で決定的に導出する (ADR-0018)。
- 変換: [`SummaryService`](../../Sources/Dahlia/Services/SummaryService.swift) の
  `decodeSummaryDocument` / `blocks(from:)` が DTO を AST へ変換し、heading level の min 3 clamp、
  画像 UUID の検証、インライン Markdown の正規化を行う。
- レンダラ: `SummaryDocumentView` (SwiftUI)、`ObsidianMarkdownSummaryRenderer` (Vault Markdown)、
  `SummaryShareRenderer` (共有 Markdown と Google Docs / Slack 向け HTML)、
  `GoogleDocsSummaryRenderer` (RTF)、`StoredSummaryDocumentMarkdownRenderer` (MCP 向け素の Markdown) の
  5 系統が `SummaryBlockContent` を exhaustive switch で処理する。これとは別に
  [`DahliaMCPServer.summaryDocumentSchema`](../../Sources/DahliaMeetingAccess/DahliaMCPServer.swift) が
  9 種の block schema を列挙する。
- 永続化: `summaries.document` TEXT 列に sortedKeys の JSON 文字列を保存する。JSON カラムのままなので、
  本 ADR の変更に DB migration は不要である。
- MCP: `update_meeting_summary` はドキュメント全体置換 + 内容ハッシュ CAS (ADR-0018)。
  [`MeetingSummaryWriteStore`](../../Sources/DahliaMeetingAccess/MeetingSummaryWriteStore.swift) の
  `validate(_:)` が `schemaVersion == 3` を強制し、
  [`StoredSummaryDocumentMarkdownRenderer.decode(toolJSON:)`](../../Sources/DahliaMeetingAccess/StoredSummaryDocumentMarkdownRenderer.swift)
  が decode → 再 encode の完全一致で往復を検証する。

また、ADR-0001 の本文と実装には食い違いがある。ADR-0001 は block-level の `transcript_refs` 配列
(`time` + `label`) を記述するが、実装は text-level の単数 `transcript_ref` (label なし) である。
本 ADR では実装を正とし、参照形式は変更しない。

Markdown の表現力を可能な限り保ちつつ、strict structured output で安定生成でき、既存の全出力先
(SwiftUI / Obsidian / 共有 Markdown / Slack / Google Docs / MCP) へ変換できる形式へ改訂する。

## Decision

block 列は平坦なまま維持し、リスト item に階層属性 `indent` を持たせる (Google Docs と同じモデル)。
あわせて `table` を LLM schema に追加する。再帰コンテナは採用しない。

### ネストリスト: item への `indent` 属性

- `bulleted_list` / `numbered_list` / `checklist` の各 item に `indent` (整数、値域は enum `[0, 1, 2]` の
  3 階層) を持たせる。
- 親子関係は「直前までの item のうち、自分より小さい indent を持つ最も近い item が親」という
  Google Docs 型の解釈で導出する。構造はレンダリング時の派生であり、永続モデルは平坦な item 列である。
- 3 階層 (indent 0〜2) に制限する。会議サマリーでこれより深い階層は可読性を下げるだけであり、
  enum にすることで strict schema でも生成が安定する。

### table を LLM schema に追加する

- block type enum に `table` を追加する。セルは plain string (`rows: [[string]]`) とし、
  セル単位の `transcript_ref` は持たせない。
- AST の `table` 型 (`headers: [SummaryText]`, `rows: [[SummaryText]]`) は無変更とし、DTO→AST 変換で
  各セルを `transcriptRef = nil` の `SummaryText` に包む。

DTO と AST の名称対応は次のとおり。

| DTO (LLM schema) | AST (`SummaryBlockContent.table`) |
| --- | --- |
| `columns: [string]` | `headers: [SummaryText]` (各要素を `SummaryText(text, transcriptRef: nil)` に変換) |
| `rows: [[string]]` | `rows: [[SummaryText]]` (同上) |
| `items[].indent` (bulleted / numbered / checklist) | `SummaryListItem.indent` / `ChecklistItem.indent` |

### AST の変更と schemaVersion 4

bulleted / numbered list の item は `[SummaryText]` から次の型に置き換える。

```swift
struct SummaryListItem: Codable, Equatable, Sendable {
    var text: String
    var transcriptRef: TranscriptReference?
    var indent: Int
}
```

- JSON 形は custom Codable で既存と同じ**平坦な** `{text, transcript_ref, indent}` を維持する
  (`text: SummaryText` の入れ子にはしない。現行 `ChecklistItem` と同じ手法)。
- `ChecklistItem` にも `indent` を追加する。
- **正準形: `indent = 0` はエンコード時に省略する** (DB 保存と `get_meeting` 出力の両方)。これにより
  旧アプリへの前方互換が安全になり、indent を使わない既存文書を再保存してもバイト差分が出ない
  (内容ハッシュ CAS が誤検知しない)。
- decode: `indent` 欠落は 0 とする。1・2 はそのまま保持する。
- 新規生成する AST は `schemaVersion = 4` とする。version 3 の既存保存データは引き続き読み取り可能で、
  decoder は現行どおりフィールド単位の寛容 decode を維持し、schemaVersion の数値で decode 挙動を
  分岐しない。

**schemaVersion 不変条件**: version 3 の文書では全 list item の `indent` が欠落または 0 のみ、
version 4 の文書では indent 0〜2 を許可する。「version 3 + 非ゼロ indent」の文書は存在させない。
`SummaryDocument` は mutable な公開モデルであるため型では構築不能にできず、この不変条件は次の
2 箇所で強制する。

1. 新規生成経路: DTO→AST 変換は常に version 4 を生成する。
2. MCP 書き込み境界: 後述の検証で「version 3 + 非ゼロ indent」を明示的に拒否する。

### DTO→AST 変換の正規化規則

LLM 出力は信用せず、変換時に次の clamp を適用する。

- 先頭 item の `indent > 0` は 0 に補正する。
- 直前の item から +2 以上飛ぶ indent は直前 item の indent + 1 に詰める。
- indent は [0, 2] に clamp する (enum を強制しないプロバイダへの保険)。
- table: `columns` が空なら block ごと破棄する。各行のセル数は `columns` 数に合わせ、
  超過は切り詰め、不足は空文字でパディングする。
- プロンプトには「indent は親子関係が明確な場合のみ使う」という使用条件を追記する。

### numbered list の番号規則 (全レンダラ共通定義)

各 indent ごとにカウンタを持つ。深い階層へ初めて入ると、その階層のカウンタを 1 から開始する。
浅い階層へ戻った場合、その浅い階層のカウンタを**継続**し、それより深い階層のカウンタを破棄する。
その後、破棄された深い階層へ再度入る場合は 1 から開始する。カウンタは永続モデルに含まれない
レンダリング時の派生状態であり、番号は変換・レンダラ側が決定し、LLM には出力させない。

規範例:

```text
indent: 0, 1, 1, 0, 1
number: 1, 1, 2, 2, 1
```

### MCP 契約の変更 (ADR-0018 の改訂)

- `update_meeting_summary` は **schemaVersion 3 と 4 の両方を受理**し、受理した version をそのまま
  保持する。3 / 4 以外は従来どおり拒否する。
- **version 3 入力に非ゼロ indent があれば、clamp や自動昇格をせず明示エラーにする**
  (上記不変条件の強制)。MCP でネストを追加したい呼び出し側は `schema_version` を 4 に更新して送る。
- `summaryDocumentSchema` の list item に `indent` を追加する (optional、既定 0、
  `{"type": "integer", "enum": [0, 1, 2]}`)。bulleted / numbered list の item は `summaryText` の
  再利用をやめ、`{text, transcript_ref, indent}` の list item schema に分離する。checklist item にも
  `indent` を追加する。table block の schema は既存のまま変更しない。
- **MCP 入力の indent 検証は clamp せず拒否する**: 0〜2 以外・整数以外は明示エラー。LLM 出力は
  clamp で救済し、ユーザーの保存データを置換する MCP 書き込みは厳格拒否する、という役割分担は
  ADR-0018 の「違反は黙って通さず明示的なエラーにする」方針と整合する。
- **往復検証の比較アルゴリズム**: 比較の前に、MCP 入力 JSON の各 list item から明示的な
  `"indent": 0` を再帰的に除去して正準形に揃える。欠落と明示 0 は同値とし、1・2 は保持する。
  この正準化を現行 `decode(toolJSON:)` の legacy defaults 補填 (`addingLegacyDefaults`) と同じ層で
  行ったうえで、従来どおり decode → 再 encode の完全一致を要求する。

往復検証の手順を擬似コードで示す。

```text
canonical(input):
    input の各 object を再帰的に走査し、
    list item の "indent": 0 を削除する          // 欠落 = 0 の正準形へ
    legacy defaults (description / tags / action_items) を補填する

decode(toolJSON: input):
    document = 寛容 decoder で input を SummaryDocument へ decode
    require canonical(input) == toolJSONValue(document)   // 未知・欠落・不正 field を検出
    require schemaVersion ∈ {3, 4}
    require schemaVersion == 3 ⇒ 全 list item の indent == 0
    require 全 list item の indent ∈ {0, 1, 2}
    require transcript_ref が HH:MM:SS に一致
```

### 互換性 / 移行方針

- DB migration は不要である (`summaries.document` は JSON カラムのまま)。
- **新 JSON (version 4) → 旧アプリ**:
  - 読み取り・表示: 寛容 decoder が未知キー `indent` を無視するため、ネストが潰れた平坦表示になる
    (graceful degradation)。クラッシュや decode 失敗にはならない。
  - 旧 MCP による version 4 文書の全置換: 旧実装の `schemaVersion == 3` チェックと往復検証
    (未知フィールド拒否) により**拒否される**。indent が黙って落ちた文書で上書きされることはない。
  - 旧アプリでサマリーを**再生成**して新しい version 3 文書で置換した場合: ネスト情報は失われる
    (lossy)。downgrade 後にネストを保持した編集・更新は保証しない。
- **旧 JSON (version 3) → 新アプリ**: `indent` 欠落 = 0 として従来どおり読み取り・表示・更新できる。
- リリースバージョニング: DB migration は不要で既存データも読み取れるが、LLM output schema と
  MCP contract が変わるため、本 ADR を実装した次回リリースは minor (`y`) を上げて patch を 0 に戻す
  ([AGENTS.md](../../AGENTS.md) の Release Versioning)。実際の番号更新はリリース準備時に行う。

## LLM Output

`SummaryDocumentResponse.outputSchema` を次のとおり改訂する。ADR-0001 の方針
(anyOf 不使用、単一 object + `type` discriminator、未使用 field も required で空値) は維持する。

- block type enum に `table` を追加する (9 種)。
- `ItemDTO` に `indent` (`{"type": "integer", "enum": [0, 1, 2]}`, required) を追加する。
- `BlockDTO` に `columns: [string]` と `rows: [[string]]` を required で追加する
  (table 以外の block では `[]`)。

新 LLM output JSON Schema 全文:

```json
{
  "type": "object",
  "properties": {
    "title": { "type": "string", "minLength": 1, "maxLength": 120 },
    "description": {
      "type": "string",
      "description": "A one-line description for quickly identifying the meeting.",
      "minLength": 1,
      "maxLength": 240
    },
    "sections": {
      "type": "array",
      "description": "Summary body sections only. Do not include an Action Items section or repeat action items here.",
      "items": {
        "type": "object",
        "properties": {
          "heading": { "type": "string" },
          "blocks": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "type": {
                  "type": "string",
                  "enum": [
                    "paragraph",
                    "bulleted_list",
                    "numbered_list",
                    "checklist",
                    "quote",
                    "code",
                    "image",
                    "heading",
                    "table"
                  ]
                },
                "level": { "type": "integer" },
                "content": {
                  "type": "object",
                  "properties": {
                    "text": { "type": "string" },
                    "transcript_ref": { "type": ["string", "null"] }
                  },
                  "required": ["text", "transcript_ref"],
                  "additionalProperties": false
                },
                "items": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "text": { "type": "string" },
                      "transcript_ref": { "type": ["string", "null"] },
                      "checked": { "type": "boolean" },
                      "indent": { "type": "integer", "enum": [0, 1, 2] }
                    },
                    "required": ["text", "transcript_ref", "checked", "indent"],
                    "additionalProperties": false
                  }
                },
                "language": { "type": "string" },
                "image_id": { "type": "string" },
                "columns": {
                  "type": "array",
                  "items": { "type": "string" }
                },
                "rows": {
                  "type": "array",
                  "items": {
                    "type": "array",
                    "items": { "type": "string" }
                  }
                }
              },
              "required": ["type", "level", "content", "items", "language", "image_id", "columns", "rows"],
              "additionalProperties": false
            }
          }
        },
        "required": ["heading", "blocks"],
        "additionalProperties": false
      }
    },
    "tags": {
      "type": "array",
      "items": { "type": "string", "pattern": "^[a-z0-9_]*[a-z][a-z0-9_]*$" }
    },
    "action_items": {
      "type": "array",
      "description": "The only location for concrete action items.",
      "items": {
        "type": "object",
        "properties": {
          "title": { "type": "string" },
          "assignee": { "type": "string" }
        },
        "required": ["title", "assignee"],
        "additionalProperties": false
      }
    }
  },
  "required": ["title", "description", "sections", "tags", "action_items"],
  "additionalProperties": false
}
```

DTO 形の完全サンプル (ネストリスト 3 階層・table・checklist・image・transcript_ref を含む):

```json
{
  "title": "Dahlia 週次ミーティング",
  "description": "サマリーフォーマット改訂の合意と次回リリースの確認。",
  "sections": [
    {
      "heading": "決定事項",
      "blocks": [
        {
          "type": "paragraph",
          "level": 0,
          "content": {
            "text": "サマリーの構造化フォーマットを改訂することで合意した。",
            "transcript_ref": "00:05:12"
          },
          "items": [],
          "language": "",
          "image_id": "",
          "columns": [],
          "rows": []
        },
        {
          "type": "bulleted_list",
          "level": 0,
          "content": { "text": "", "transcript_ref": null },
          "items": [
            { "text": "フォーマット改訂", "transcript_ref": "00:06:03", "checked": false, "indent": 0 },
            { "text": "ネストリスト対応", "transcript_ref": null, "checked": false, "indent": 1 },
            { "text": "最大 3 階層まで", "transcript_ref": null, "checked": false, "indent": 2 },
            { "text": "table 対応", "transcript_ref": null, "checked": false, "indent": 1 },
            { "text": "リリース計画", "transcript_ref": "00:21:40", "checked": false, "indent": 0 }
          ],
          "language": "",
          "image_id": "",
          "columns": [],
          "rows": []
        },
        {
          "type": "table",
          "level": 0,
          "content": { "text": "", "transcript_ref": null },
          "items": [],
          "language": "",
          "image_id": "",
          "columns": ["項目", "担当", "期限"],
          "rows": [
            ["スキーマ改訂", "mats", "8/15"],
            ["レンダラ更新", "mats", "8/22"]
          ]
        }
      ]
    },
    {
      "heading": "残タスク",
      "blocks": [
        {
          "type": "checklist",
          "level": 0,
          "content": { "text": "", "transcript_ref": null },
          "items": [
            { "text": "プロンプト調整", "transcript_ref": "00:32:18", "checked": false, "indent": 0 },
            { "text": "indent の使用条件を明記", "transcript_ref": null, "checked": true, "indent": 1 }
          ],
          "language": "",
          "image_id": "",
          "columns": [],
          "rows": []
        },
        {
          "type": "image",
          "level": 0,
          "content": {
            "text": "リリース計画のホワイトボード",
            "transcript_ref": "00:28:55"
          },
          "items": [],
          "language": "",
          "image_id": "0198A3C2-7F41-7D02-9B3E-1A2B3C4D5E6F",
          "columns": [],
          "rows": []
        }
      ]
    }
  ],
  "tags": ["dahlia", "release"],
  "action_items": [
    { "title": "ADR を執筆する", "assignee": "mats" }
  ]
}
```

## Persistence

DB には従来どおり `summaries.document` に sortedKeys の JSON 文字列を保存する。上記 DTO を変換した
永続 AST 形のサンプル (section / block id はアプリが `UUID.v7()` で採番。`indent = 0` は省略される
点に注意):

```json
{
  "schemaVersion": 4,
  "title": "Dahlia 週次ミーティング",
  "description": "サマリーフォーマット改訂の合意と次回リリースの確認。",
  "sections": [
    {
      "id": "0198A3C2-8000-7000-8000-000000000001",
      "heading": "決定事項",
      "blocks": [
        {
          "id": "0198A3C2-8000-7000-8000-000000000002",
          "type": "paragraph",
          "content": {
            "text": "サマリーの構造化フォーマットを改訂することで合意した。",
            "transcript_ref": "00:05:12"
          }
        },
        {
          "id": "0198A3C2-8000-7000-8000-000000000003",
          "type": "bulleted_list",
          "items": [
            { "text": "フォーマット改訂", "transcript_ref": "00:06:03" },
            { "text": "ネストリスト対応", "indent": 1 },
            { "text": "最大 3 階層まで", "indent": 2 },
            { "text": "table 対応", "indent": 1 },
            { "text": "リリース計画", "transcript_ref": "00:21:40" }
          ]
        },
        {
          "id": "0198A3C2-8000-7000-8000-000000000004",
          "type": "table",
          "headers": [
            { "text": "項目" },
            { "text": "担当" },
            { "text": "期限" }
          ],
          "rows": [
            [{ "text": "スキーマ改訂" }, { "text": "mats" }, { "text": "8/15" }],
            [{ "text": "レンダラ更新" }, { "text": "mats" }, { "text": "8/22" }]
          ]
        }
      ]
    },
    {
      "id": "0198A3C2-8000-7000-8000-000000000005",
      "heading": "残タスク",
      "blocks": [
        {
          "id": "0198A3C2-8000-7000-8000-000000000006",
          "type": "checklist",
          "items": [
            { "text": "プロンプト調整", "transcript_ref": "00:32:18", "checked": false },
            { "text": "indent の使用条件を明記", "checked": true, "indent": 1 }
          ]
        },
        {
          "id": "0198A3C2-8000-7000-8000-000000000007",
          "type": "image",
          "screenshot_id": "0198A3C2-7F41-7D02-9B3E-1A2B3C4D5E6F",
          "content": {
            "text": "リリース計画のホワイトボード",
            "transcript_ref": "00:28:55"
          }
        }
      ]
    }
  ],
  "tags": ["dahlia", "release"],
  "actionItems": [
    { "title": "ADR を執筆する", "assignee": "mats" }
  ]
}
```

(実際の保存形は sortedKeys でキーが辞書順に並ぶ。ここでは読みやすさのため論理順で示した。
MCP の tool 形では `schemaVersion` → `schema_version`、`actionItems` → `action_items` に
綴りが変わる点は現行どおり。)

## Rendering

各出力先の変換方針。table は AST として既存対応済みのため、確認のみを記す。

| 出力先 | ネストリスト | table (既存対応の確認のみ) |
| --- | --- | --- |
| SwiftUI (`SummaryDocumentView`) | `indent ×` 定数 padding | `Grid` (既存) |
| Obsidian / MCP Markdown | indent × 4 スペース prefix (`    - item`)。numbered は上記番号規則 | pipe table (既存) |
| 共有 Markdown (`SummaryShareRenderer`) | 同上 | 同上 |
| 共有 HTML: Google Docs 向け | `<ul>` / `<ol>` のネスト構築 (平坦列をスタックで走査して開閉タグを生成) | `<table>` (既存) |
| 共有 HTML: Slack 向け | Slack はネスト `<ul>` 非対応のため擬似 indent (スペース) | pipe テキスト (既存) |
| Google Docs RTF (`GoogleDocsSummaryRenderer`) | `\li{720×(indent+1)}` + `\fi-360` の段階化 | タブ区切り (既存) |

## Consequences

- ネストリスト (3 階層) と LLM 生成の table が全出力先で使えるようになり、会議サマリーの
  親子関係と俯瞰表を構造のまま保持できる。
- レンダラ 5 系統 + MCP schema + DTO→AST 変換 + テストの実装コストがかかる。特に
  共有 HTML のネスト `<ul>` / `<ol>` 構築と numbered list の番号規則は全レンダラで
  同一の共通定義に従う必要がある。
- LLM が indent を乱発するリスクがある。正規化規則 (先頭 0 強制、+2 以上のジャンプ詰め、
  [0, 2] clamp) とプロンプトの使用条件で抑制する。
- 旧アプリとの共存: 旧アプリは version 4 文書を平坦表示でき、旧 MCP は version 4 文書の
  上書きを拒否する。ただし旧アプリでの再生成は version 3 で置換するため、ネスト情報は失われる。
- `indent = 0` 省略の正準形により、indent を使わない既存文書は再保存してもバイト列が変わらず、
  内容ハッシュ CAS (ADR-0018) と決定的 block id の前提を壊さない。
- LLM output schema と MCP contract の変更であるため、実装後の次回リリースは minor を上げて
  patch を 0 に戻す。
- 実装時には、生成経路の「常に 4」と MCP 境界の「3 と 4 を受理」が参照する schemaVersion を
  リテラルの重複ではなく `DahliaRuntimeSupport` の共有定数 (現行版と受理集合) に一元化し、
  アプリと MCP ヘルパーの両ターゲットで不変条件の判定源を 1 つにする。
- 残課題: indent と table の使用条件を含むプロンプト調整は実装時に行い、生成品質を見て反復する。

## Alternatives Considered

### 再帰コンテナ (Notion block model)

block が `children: [Block]` を持ち任意深度にネストする形。strict structured output では
`$defs` + `$ref` の自己再帰が必要になるが、Codex app-server 経由で利用する複数プロバイダ
(OpenAI / Databricks / vLLM 系) の strict schema 対応が不揃いで、対応していてもモデルが深い再帰を
安定生成できない。全レンダラも再帰 walk になり、得られる表現力に対して実装量が見合わない。却下した。

### item ごとの `children` 配列 (非再帰 1 段)

list item に 1 段だけの `children` を持たせる形。再帰は避けられるが 2 階層しか取れず、
3 階層の要求を満たさない。schema のネストも深くなり、生成の安定性でも indent 属性に劣る。却下した。

### 引用内ブロック / callout

quote が block の配列を内包する形。再帰が必要になるうえ、Slack / RTF での表現も乏しい。
ユーザー確認のうえ却下した。

### テーブルセルを `{text, transcript_ref}` object にする

AST の `table` と同形にセル単位の transcript 参照を許す形。出力トークン量が約 2 倍になり
生成安定性が下がる。表は俯瞰用途でありセル単位参照のニーズが薄い (ユーザー確認済み)。却下した。
AST 側は `[[SummaryText]]` のままであるため、将来必要になれば LLM schema だけを拡張できる。

### インライン AST 化 (bold / link の構造化)

段落内の強調やリンクを構造化ノードにする形。現行の inline Markdown 文字列 +
AttributedString パースで各出力先へ変換できており、構造化しても利得がない。却下した。

### heading 層の拡張 / sections 廃止

`sections` をやめて heading block だけで階層を表す形。section UUID は Google Docs の部分更新、
Slack の分割投稿、MCP の block 同一性 (ADR-0018) の前提であり、sections は LLM 出力の骨格を
安定させる効果もあるため維持する。却下した。
