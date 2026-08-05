# ADR-0024: サマリーブロックを平坦な階層属性で拡張する

## Status

Proposed; amends 0001 and 0018

## Date

2026-08-05

## Context

ADR-0001 は `SummaryDocument` AST をサマリーの正準表現にし、LLM が返す strict structured output を DTO から
AST へ変換して、表示先ごとの renderer へ渡す方針を定めた。現在の LLM 出力は `title` を H1、section の
`heading` を H2、heading block を H3 以上として扱う実質 3 層の見出し構造を持つ。一方、section は再帰せず、
list item は階層を持たず、LLM output schema から table を除外している。そのため、Markdown が表現できる
ネストリストと表を生成結果に保てない。

現行実装は次のとおりである。

- [`SummaryDocumentResponse.swift`](../../Sources/Dahlia/Models/SummaryDocumentResponse.swift) の DTO は、8 種類の
  `type` discriminator を持つ単一の block object を使う。`anyOf` は使わず、未使用 field を含む全 field を
  required にする。`table` は LLM output schema から除外している。
- [`SummaryDocument.swift`](../../Sources/DahliaRuntimeSupport/SummaryDocument.swift) の正準 AST は
  `schemaVersion = 3` で、DTO より 1 種多い `table` を含む 9 種類の `SummaryBlockContent` を持つ。未知の block
  `type` は paragraph へフォールバックし、block id がない旧文書では coding path を FNV-1a で処理して id を
  決定的に導出する。
- [`SummaryService.swift`](../../Sources/Dahlia/Services/SummaryService.swift) の `decodeSummaryDocument` と
  `blocks(from:context:)` が DTO を AST に変換し、heading level を最低 3 に補正し、image UUID と Meeting への所属を
  検証し、空 block と文字列を正規化する。
- `SummaryDocumentView`、`ObsidianMarkdownSummaryRenderer`、`SummaryShareRenderer` の Markdown / HTML、
  `GoogleDocsSummaryRenderer` の RTF、`StoredSummaryDocumentMarkdownRenderer` の MCP Markdown が、
  `SummaryBlockContent` を exhaustive switch で処理する。これとは別に
  `DahliaMCPServer.summaryDocumentSchema` が MCP 公開形の 9 種類の block schema を列挙する。
- `SummaryDocument.databaseJSONString()` は sorted keys の JSON を `summaries.document` TEXT に保存する。
  block 内容を拡張しても列型は変わらないため、DB migration は必要ない。
- ADR-0018 の `update_meeting_summary` は、ドキュメント全体を内容ハッシュによる CAS 付きで置換する。
  [`MeetingSummaryWriteStore.swift`](../../Sources/DahliaMeetingAccess/MeetingSummaryWriteStore.swift) は現在
  `schemaVersion == 3` を要求し、
  [`StoredSummaryDocumentMarkdownRenderer.swift`](../../Sources/DahliaMeetingAccess/StoredSummaryDocumentMarkdownRenderer.swift)
  は MCP 入力を decode して再 encode した結果との完全一致で、未知 field、欠落 field、無効な field が失われないことを
  検証する。

ADR-0001 の本文と実装には文字起こし参照形式の食い違いがある。ADR-0001 は block-level の複数
`transcript_refs` と `label` を記述するが、現在の実装は `SummaryText` ごとの単数 `transcript_ref` を時刻文字列として
保持し、label を持たない。本 ADR は**実装を正**とし、文字起こし参照の形を変更しない。

必要なのは、Markdown の表現力を可能な限り保ちながら、Codex app-server 経由で利用する OpenAI、Databricks、
vLLM 系の各 provider が、自己再帰や `anyOf` に依存せず安定して生成できる形式である。また、既存の SwiftUI、
Obsidian、共有 Markdown、Slack、Google Docs、MCP の全出力先へ決定的に変換できなければならない。

## Decision

section と block の平坦な配列を維持し、list item に `indent`、block に `table` 用 field を追加する。
再帰コンテナは導入しない。Google Docs の段落モデルと同様に、読み順は配列順、階層は item の属性で表す。

### 階層の範囲

`bulleted_list`、`numbered_list`、`checklist` の各 item に required の整数 `indent` を追加する。値は
`0`、`1`、`2` のいずれかで、0 を親なしの最上位、1 と 2 をそれぞれ 1 段、2 段深い item とする。

この 3 階層は、通常の会議サマリーで必要な親子関係を表現しつつ、LLM の過剰なネストと各 renderer の複雑さを
有限に保つための上限である。引用内へ block をネストする機能は導入しない。

### DTO と AST の名称対応

LLM DTO と永続 AST は目的が異なるため、table と list item の field を次のように変換する。

| LLM DTO | 正準 AST | 変換 |
| --- | --- | --- |
| `columns: [String]` | `headers: [SummaryText]` | 各 string を `SummaryText(value, transcriptRef: nil)` で包む |
| `rows: [[String]]` | `rows: [[SummaryText]]` | 各 string を `SummaryText(value, transcriptRef: nil)` で包む |
| `items[].indent` | `SummaryListItem.indent` / `ChecklistItem.indent` | 空 item の破棄後に正規化し、0...2 の整数として保持する |

LLM DTO の table cell は `transcript_ref` を持たず、DTO から生成する AST の cell も参照を nil にする。表は情報を
俯瞰する用途であり、cell ごとの参照を要求すると schema と出力の token 量が大きくなって生成安定性が落ちるためである。
AST の既存 table case と MCP 公開形は変更せず、保存済み文書または MCP 入力の table cell が持つ既存の
`transcript_ref` は読み取り、往復時とも保持する。

## LLM Output

### DTO の変更

`SummaryDocumentResponse.BlockDTO.ItemDTO` に required の `indent: Int` を追加する。block `type` enum に `table` を
追加し、`BlockDTO` に required の `columns: [String]` と `rows: [[String]]` を追加する。table 以外の block は
`columns: []` と `rows: []` を返す。table は `content`、`items`、`language`、`image_id` を従来の未使用 field と同じ
空値にする。

新しい LLM output JSON Schema の全文は次のとおりである。

```json
{
  "type": "object",
  "properties": {
    "title": {
      "type": "string",
      "minLength": 1,
      "maxLength": 120
    },
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
          "heading": {
            "type": "string"
          },
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
                "level": {
                  "type": "integer"
                },
                "content": {
                  "type": "object",
                  "properties": {
                    "text": {
                      "type": "string"
                    },
                    "transcript_ref": {
                      "type": [
                        "string",
                        "null"
                      ]
                    }
                  },
                  "required": [
                    "text",
                    "transcript_ref"
                  ],
                  "additionalProperties": false
                },
                "items": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "properties": {
                      "text": {
                        "type": "string"
                      },
                      "transcript_ref": {
                        "type": [
                          "string",
                          "null"
                        ]
                      },
                      "checked": {
                        "type": "boolean"
                      },
                      "indent": {
                        "type": "integer",
                        "enum": [
                          0,
                          1,
                          2
                        ]
                      }
                    },
                    "required": [
                      "text",
                      "transcript_ref",
                      "checked",
                      "indent"
                    ],
                    "additionalProperties": false
                  }
                },
                "language": {
                  "type": "string"
                },
                "image_id": {
                  "type": "string"
                },
                "columns": {
                  "type": "array",
                  "maxItems": 12,
                  "items": {
                    "type": "string"
                  }
                },
                "rows": {
                  "type": "array",
                  "maxItems": 50,
                  "items": {
                    "type": "array",
                    "maxItems": 12,
                    "items": {
                      "type": "string"
                    }
                  }
                }
              },
              "required": [
                "type",
                "level",
                "content",
                "items",
                "language",
                "image_id",
                "columns",
                "rows"
              ],
              "additionalProperties": false
            }
          }
        },
        "required": [
          "heading",
          "blocks"
        ],
        "additionalProperties": false
      }
    },
    "tags": {
      "type": "array",
      "items": {
        "type": "string",
        "pattern": "^[a-z0-9_]*[a-z][a-z0-9_]*$"
      }
    },
    "action_items": {
      "type": "array",
      "description": "The only location for concrete action items.",
      "items": {
        "type": "object",
        "properties": {
          "title": {
            "type": "string"
          },
          "assignee": {
            "type": "string"
          }
        },
        "required": [
          "title",
          "assignee"
        ],
        "additionalProperties": false
      }
    }
  },
  "required": [
    "title",
    "description",
    "sections",
    "tags",
    "action_items"
  ],
  "additionalProperties": false
}
```

この schema に従う DTO の完全な例を示す。未使用 field も省略しない。

```json
{
  "title": "新しいサマリー形式の設計",
  "description": "階層リストと表を平坦な structured output で扱う方針を決めた会議",
  "sections": [
    {
      "heading": "設計方針",
      "blocks": [
        {
          "type": "paragraph",
          "level": 0,
          "content": {
            "text": "再帰コンテナを使わず、item の属性で階層を表現する。",
            "transcript_ref": "00:03:12"
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
          "content": {
            "text": "",
            "transcript_ref": null
          },
          "items": [
            {
              "text": "平坦な block 配列を維持する",
              "transcript_ref": "00:04:01",
              "checked": false,
              "indent": 0
            },
            {
              "text": "list item に indent を持たせる",
              "transcript_ref": "00:04:18",
              "checked": false,
              "indent": 1
            },
            {
              "text": "最大値は 2 にする",
              "transcript_ref": null,
              "checked": false,
              "indent": 2
            }
          ],
          "language": "",
          "image_id": "",
          "columns": [],
          "rows": []
        },
        {
          "type": "numbered_list",
          "level": 0,
          "content": {
            "text": "",
            "transcript_ref": null
          },
          "items": [
            {
              "text": "DTO を検証する",
              "transcript_ref": null,
              "checked": false,
              "indent": 0
            },
            {
              "text": "AST に変換する",
              "transcript_ref": null,
              "checked": false,
              "indent": 1
            },
            {
              "text": "renderer で派生番号を付ける",
              "transcript_ref": "00:08:42",
              "checked": false,
              "indent": 1
            }
          ],
          "language": "",
          "image_id": "",
          "columns": [],
          "rows": []
        },
        {
          "type": "table",
          "level": 0,
          "content": {
            "text": "",
            "transcript_ref": null
          },
          "items": [],
          "language": "",
          "image_id": "",
          "columns": [
            "出力先",
            "ネスト表現"
          ],
          "rows": [
            [
              "Obsidian",
              "4 spaces"
            ],
            [
              "SwiftUI",
              "padding"
            ]
          ]
        },
        {
          "type": "checklist",
          "level": 0,
          "content": {
            "text": "",
            "transcript_ref": null
          },
          "items": [
            {
              "text": "JSON Schema を更新する",
              "transcript_ref": "00:12:05",
              "checked": true,
              "indent": 0
            },
            {
              "text": "全 renderer を更新する",
              "transcript_ref": null,
              "checked": false,
              "indent": 1
            }
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
            "text": "ホワイトボードに描いた変換フロー",
            "transcript_ref": "00:14:20"
          },
          "items": [],
          "language": "",
          "image_id": "0198a8d6-7830-7c61-8b69-933ac8bbed8e",
          "columns": [],
          "rows": []
        }
      ]
    }
  ],
  "tags": [
    "summary_format",
    "structured_output"
  ],
  "action_items": [
    {
      "title": "実装計画を作成する",
      "assignee": "Kazuki"
    }
  ]
}
```

### DTO から AST への正規化

LLM 出力は schema 検証後も、意味的に不自然な indent と不揃いな table row を含みうる。
`SummaryService.document(from:context:)` と `blocks(from:context:)` で次の順に正規化する。

1. 各 list item の本文と `transcript_ref` を既存規則で正規化し、本文が空の item を破棄する。以降の indent 補正は、
   この破棄後に残った item 列だけを対象にする。
2. 残った各 item の `indent` を 0...2 に clamp する。
3. 残った list の先頭 item が 1 または 2 なら 0 にする。
4. 直前 item から 2 段以上深くなる場合は、直前 item の indent + 1 まで詰める。
5. table の `columns` は先頭 12 件、`rows` は先頭 50 件までに制限する。structured output schema にも同じ
   `maxItems` を指定するが、制約を守らない provider に備えて変換境界でも再適用する。
6. 制限後の `columns` が空なら block 全体を破棄する。
7. 各 row が `columns.count` より長ければ末尾を切り詰め、短ければ空文字を追加する。これにより生成される table は
   1 block あたり最大 12 columns、50 body rows、600 body cells に制限され、header を含む描画 cell 数も最大 612 になる。
8. `columns` と正規化済みの各 cell を `transcriptRef: nil` の `SummaryText` へ変換する。
9. DTO から 1 文書を変換する間、table の header と body を合わせて 1,200 描画 cells の残量 budget を持つ。
   section と block の読み順に table を処理し、各 table の header 分を確保したあと、残量に収まる先頭 body rows だけを
   保持する。header が残量に収まらない table と、budget を使い切った後の table は破棄する。この文書全体の上限は
   JSON Schema だけでは表せないため、変換境界で必ず強制する。

たとえば `2, 0, 2, 2, 7` は、先頭補正、飛び越し補正、範囲補正の結果 `0, 0, 1, 2, 2` になる。
これは LLM の非決定的な出力を利用可能な AST へ直す境界の処理であり、ユーザーの保存データを置換する MCP 入力には
適用しない。

サマリープロンプトには、`indent` は親子関係が明確な場合だけ使い、単なる強調や項目数の少ないリストを不要に
ネストしないことを追記する。table が適する比較・対応関係では table を使い、セルに transcript link や
`transcript_ref` を出力させない。複数の小さな table へ過剰に分割せず、比較に必要な行と列だけを出力させる。

## Persistence

### list item の永続形

bulleted list と numbered list の item を `SummaryText` から `SummaryListItem` へ変更し、checklist item にも
`indent` を追加する。モデル上は本文、単数の文字起こし参照、indent を持つが、JSON は `SummaryText` を入れ子にせず
既存 checklist item と同じ平坦な形を維持する。

```swift
struct SummaryListItem: Codable, Equatable, Sendable {
    var text: SummaryText
    var indent: Int
}

struct ChecklistItem: Codable, Equatable, Sendable {
    var text: SummaryText
    var checked: Bool
    var indent: Int
}
```

それぞれ custom `Codable` で次の JSON へ対応させる。

```json
{
  "text": "list item text",
  "transcript_ref": "00:04:18",
  "indent": 1
}
```

- decode 時は `indent` 欠落を 0 とする。整数以外は decode error にする。値 1 と 2 はそのまま保持する。
- encode 時は `indent == 0` を省略し、1 と 2 だけを出力する。
- `transcript_ref` はこれまでどおり optional とし、nil なら省略する。
- checklist item は同じ object に required の `checked` を持つ。

`indent = 0` の省略形を正準形にすることで、indent を使わない schema version 3 の文書を新しいアプリが読み、
再保存しても item ごとの `"indent": 0` による不要なバイト差分を発生させない。これは内容ハッシュを CAS token に使う
ADR-0018 にとっても重要である。

### schema version

新規生成する `SummaryDocument` は `schemaVersion = 4` とする。version 3 の保存済み文書は引き続き読み取る。
decoder は version ごとの型分岐を増やさず、これまでどおり field 単位の寛容な decode を行う。

ただし、次の不変条件を設ける。

- version 3: 全 list / checklist item の indent は、JSON で欠落しているか、意味上 0 でなければならない。
- version 4: 全 list / checklist item の indent は 0...2 でなければならない。
- `schemaVersion = 3` かつ非ゼロ indent の文書は正当な保存状態として存在させない。

version 4 の各 list / checklist item 列には、さらに次の構造不変条件を設ける。

- 全 item の本文は、whitespace を除いて空でない。
- 空でない列の先頭 item は indent 0 である。
- 直前 item より深くなる場合、増加幅は 1 以下である。浅い階層へ戻る幅は制限しない。

`SummaryDocument` は mutable な公開モデルであるため、この組み合わせを型だけで構築不能にはしない。不変条件は、
新規生成経路が空 item の破棄後に indent を正規化して常に version 4 を付けることと、MCP 書き込み境界が version、
全 indent、各 item 列の構造を検証することで強制する。

### schema version の判定源

実装時は、新規生成に使う現行 schema version と MCP 書き込みで受理する version 集合を
`DahliaRuntimeSupport` の共有定数へ一元化する。名称は実装時に既存 API と揃えるが、意味上は次の 2 値を公開する。

```swift
public enum SummaryDocumentSchemaVersion {
    public static let current = 4
    public static let acceptedMCPWriteVersions: Set<Int> = [3, 4]
}
```

- アプリターゲットは `SummaryDocument` の新規生成既定値と DTO-to-AST 変換で `current` を使い、常に version 4 を生成する。
- MCP ヘルパーは `MeetingSummaryWriteStore` の受理判定で `acceptedMCPWriteVersions` を使う。version 3 / 4 のリテラルを
  各ターゲットへ重複させない。
- この集合は**書き込み境界だけ**の契約である。field 単位の寛容な decoder と `get_meeting` の共有 schema は整数一般を
  引き続き読み取り、version 2 などの legacy 文書を拒否しない。
- version ごとの indent、blank item、item 列構造の不変条件も、この共有された version 判定結果を基準に適用する。

DTO 例を変換した正準 AST JSON は次のようになる。正準形なので indent 0 は省略している。table の header と cell は
AST の既存型に合わせて `SummaryText` object だが、すべて `transcript_ref` を持たない。

```json
{
  "schemaVersion": 4,
  "title": "新しいサマリー形式の設計",
  "description": "階層リストと表を平坦な structured output で扱う方針を決めた会議",
  "sections": [
    {
      "id": "0198a8d8-1000-7a01-8000-000000000001",
      "heading": "設計方針",
      "blocks": [
        {
          "id": "0198a8d8-1000-7a01-8000-000000000002",
          "type": "paragraph",
          "content": {
            "text": "再帰コンテナを使わず、item の属性で階層を表現する。",
            "transcript_ref": "00:03:12"
          }
        },
        {
          "id": "0198a8d8-1000-7a01-8000-000000000003",
          "type": "bulleted_list",
          "items": [
            {
              "text": "平坦な block 配列を維持する",
              "transcript_ref": "00:04:01"
            },
            {
              "text": "list item に indent を持たせる",
              "transcript_ref": "00:04:18",
              "indent": 1
            },
            {
              "text": "最大値は 2 にする",
              "indent": 2
            }
          ]
        },
        {
          "id": "0198a8d8-1000-7a01-8000-000000000004",
          "type": "numbered_list",
          "items": [
            {
              "text": "DTO を検証する"
            },
            {
              "text": "AST に変換する",
              "indent": 1
            },
            {
              "text": "renderer で派生番号を付ける",
              "transcript_ref": "00:08:42",
              "indent": 1
            }
          ]
        },
        {
          "id": "0198a8d8-1000-7a01-8000-000000000005",
          "type": "table",
          "headers": [
            {
              "text": "出力先"
            },
            {
              "text": "ネスト表現"
            }
          ],
          "rows": [
            [
              {
                "text": "Obsidian"
              },
              {
                "text": "4 spaces"
              }
            ],
            [
              {
                "text": "SwiftUI"
              },
              {
                "text": "padding"
              }
            ]
          ]
        },
        {
          "id": "0198a8d8-1000-7a01-8000-000000000006",
          "type": "checklist",
          "items": [
            {
              "text": "JSON Schema を更新する",
              "transcript_ref": "00:12:05",
              "checked": true
            },
            {
              "text": "全 renderer を更新する",
              "checked": false,
              "indent": 1
            }
          ]
        },
        {
          "id": "0198a8d8-1000-7a01-8000-000000000007",
          "type": "image",
          "screenshot_id": "0198a8d6-7830-7c61-8b69-933ac8bbed8e",
          "content": {
            "text": "ホワイトボードに描いた変換フロー",
            "transcript_ref": "00:14:20"
          }
        }
      ]
    }
  ],
  "tags": [
    "summary_format",
    "structured_output"
  ],
  "actionItems": [
    {
      "title": "実装計画を作成する",
      "assignee": "Kazuki"
    }
  ]
}
```

## Numbered Lists

numbered list の表示番号は永続モデルにも LLM 出力にも含めず、renderer が item の並びと indent から導出する。
各 indent に独立した counter を持ち、次の規則を全 renderer で共有する。

1. 最上位を含め、その indent へ初めて入ると counter を 1 から開始する。
2. 同じ indent の次の item では、その indent の counter を 1 増やす。
3. 浅い indent へ戻った場合、その浅い indent の counter を継続し、それより深い counter を破棄する。
4. 破棄した深い indent へ再度入った場合、その counter は 1 から再開する。

規範例は次のとおりである。

```text
indent: 0, 1, 1, 0, 1
number: 1, 1, 2, 2, 1
```

たとえば Markdown では次の表示になる。

```markdown
1. first
    1. first child
    2. second child
2. second
    1. reset child
```

## Rendering

各 renderer は平坦な item 配列を読み、次の規則で既存の出力へ変換する。table はすでに AST と各 renderer に存在するため、
LLM から到達可能になることを確認するだけで表現方式は変更しない。

| 出力先 | ネストリスト | table |
| --- | --- | --- |
| SwiftUI (`SummaryDocumentView`) | `indent *` 定数値の leading padding | 既存の `Grid` |
| Obsidian / MCP Markdown | `indent * 4` spaces を marker の前に付ける。numbered は共通 counter 規則を使う | 既存の pipe table |
| Share Markdown | Obsidian / MCP Markdown と同じ | 既存の pipe table |
| Share HTML (Google Docs) | 平坦列を stack で処理して `<ul>` / `<ol>` を開閉する | 既存の `<table>` |
| Share HTML (Slack) | Slack の nested list 制約に合わせ、marker 前へ `indent * 4` 個の non-breaking space (`&nbsp;`) を置いて擬似 indent する | 既存の pipe text |
| Google Docs RTF | `\li{720 * (indent + 1)}` と `\fi-360` で段階化する | 既存の tab 区切り |

SwiftUI の padding 定数は実装時に Dynamic Type と既存 marker の配置を確認して決める。indent の視覚表現は
projection であり、元の item と indent は失わない。HTML renderer は list type ごとに stack を作り、同じ block 内の
indent 遷移だけを処理する。異なる block をまたいで list を連結しない。Slack 向け HTML は通常の space を使うと
HTML whitespace collapsing で階層が失われるため、non-breaking space を規範形とする。実装テストでは HTML flavor と
plain-text flavor の両方について、indent が保持されることを確認する。

## MCP Contract

ADR-0018 の `get_meeting.summary_document` と `update_meeting_summary.summary_document` の共有 schema を改訂する。

### schema 差分

`schema_version` は共有 schema では整数のままにする。`get_meeting` は現行 decoder が読み取れる version 2 などの
保存済み legacy 文書も受け取り時の version のまま返すため、共有する出力 schema を 3 と 4 に狭めてはならない。
書き込み時に 3 と 4 だけを受理する規則は `MeetingSummaryWriteStore` の検証で強制する。

paragraph、quote、code、image、heading、table が使う `SummaryText` schema は変えず、bulleted / numbered list 専用の
item schema を分けて optional の `indent` を追加する。checklist item にも同じ optional field を追加する。MCP では
欠落を 0 とみなすため、`indent` は required にしない。

```json
{
  "list_item": {
    "type": "object",
    "properties": {
      "text": {
        "type": "string"
      },
      "transcript_ref": {
        "type": "string",
        "pattern": "^[0-9]{2,}:[0-9]{2}:[0-9]{2}$"
      },
      "indent": {
        "type": "integer",
        "enum": [
          0,
          1,
          2
        ],
        "default": 0
      }
    },
    "required": [
      "text"
    ],
    "additionalProperties": false
  },
  "checklist_item": {
    "type": "object",
    "properties": {
      "text": {
        "type": "string"
      },
      "transcript_ref": {
        "type": "string",
        "pattern": "^[0-9]{2,}:[0-9]{2}:[0-9]{2}$"
      },
      "checked": {
        "type": "boolean"
      },
      "indent": {
        "type": "integer",
        "enum": [
          0,
          1,
          2
        ],
        "default": 0
      }
    },
    "required": [
      "text",
      "checked"
    ],
    "additionalProperties": false
  }
}
```

これは説明用に変更部分へ名前を付けた fragment である。実際の `summaryDocumentSchema` では `list_item` を
`bulleted_list` と `numbered_list` の `items.items` に、`checklist_item` を `checklist` の `items.items` に展開する。
table の `headers` と `rows` は引き続き indent を持たない `SummaryText` schema を使う。

### 受理と検証

`update_meeting_summary` は schema version 3 と 4 を受理し、受理した version をそのまま保存する。3 と 4 以外は
従来どおり明示エラーにする。

MCP 入力はユーザーの保存済み文書を全置換するため、LLM DTO のような clamp を行わない。

- indent が整数でない場合は decode error にする。
- indent が 0...2 でない場合は明示エラーにする。
- version 4 の list / checklist item の本文が whitespace を除いて空なら明示エラーにする。削除や別 item への参照移動は
  行わない。version 3 にすでに存在しうる blank item は legacy 互換のためこの新規条件では拒否しない。
- 空でない list / checklist の先頭 item が indent 0 でない場合、または直前 item から indent が 2 以上増える場合は
  明示エラーにする。LLM 出力のような先頭補正や飛び越し補正は行わない。
- version 3 の文書に 1 または 2 の indent が 1 件でもあれば明示エラーにする。version 4 への自動昇格も、indent の
  0 への clamp も行わない。ネストを追加する呼び出し側が `schema_version` を 4 に変更して送る。
- 欠落した indent と明示された 0 は同値として受理する。

### 往復検証

`StoredSummaryDocumentMarkdownRenderer.decode(toolJSON:)` の完全一致検証は維持する。ただし encode 時に indent 0 を
省略する正準形と MCP 入力の明示 0 を同値にするため、比較前に入力を正準化する。

1. MCP 入力 JSON の `sections[].blocks[]` を走査する。
2. `type` が `bulleted_list`、`numbered_list`、`checklist` の block だけを対象に、各 `items[]` object の
   `"indent": 0` を除去する。1 と 2 は保持する。他の object から同名 field を一般的に除去しない。
3. 現行の `addingLegacyDefaults` と同じ層で、欠落可能な top-level legacy defaults と indent 0 の正準化を行う。
4. snake_case の MCP 形を database key へ変換し、`SummaryDocument` として decode する。
5. decode 結果について schema version と、その version に適用される本文、indent、item 列の構造不変条件を検証する。
6. MCP の snake_case 形へ再 encode し、手順 2 と 3 で正準化した入力と完全一致を要求する。

これにより未知 field、欠落した required field、型不一致は引き続き拒否され、明示 0 だけが正準化による差分として
許可される。非ゼロ indent を round-trip の都合で失ったり、version 3 の文書へ紛れ込ませたりしない。

擬似コードでは次の順になる。`canonicalToolInput` は任意の object から `indent` を消すのではなく、list / checklist
block の `items[]` だけを対象にする。

```text
canonicalToolInput(input):
    normalized = addingLegacyDefaults(input)
    for block in normalized.sections[].blocks[]:
        if block.type in {bulleted_list, numbered_list, checklist}:
            for item in block.items[]:
                if item.indent == 0:
                    remove item.indent
    return normalized

decodeForMCPWrite(input):
    canonical = canonicalToolInput(input)
    document = decode(rewriteToolKeysToDatabaseKeys(input))
    require acceptedMCPWriteVersions.contains(document.schemaVersion)
    require versionedListInvariantsAreValid(document)
    require transcriptReferencesAreValid(document)
    require canonical == toolJSONValue(document)
    return document
```

## Compatibility and Migration

DB migration は行わない。`summaries.document` は引き続き TEXT の JSON column であり、新しい field と
`schemaVersion = 4` は document JSON 内だけの変更である。

### version 2 以前の legacy JSON を新しいアプリで扱う場合

- 現行の field 単位の寛容な decoder を維持し、読み取り可能な文書は受け取った schema version のまま表示する。
- `get_meeting` の共有 schema は `schema_version: integer` のままなので、version 2 などの保存済み文書も引き続き
  `summary_document` として返せる。
- `update_meeting_summary` は書き込み境界で version 3 と 4 だけを受理するため、legacy version の文書を更新する呼び出し側は
  現行 AST へ更新し、少なくとも version 3 として送る。

### version 3 の JSON を新しいアプリで扱う場合

- indent 欠落を 0 として decode し、従来どおり平坦に表示する。
- 再保存時も indent 0 を省略するため、階層を使わない item の wire shape は変わらない。
- 新しいアプリが LLM から再生成する文書は version 4 になる。

### version 4 の JSON を古いアプリで扱う場合

- 読み取りと表示では、Swift `Decodable` が未知の `indent` key を無視するため、list は平坦になるが文書自体は表示できる。
  現行 decoder は `schemaVersion` の値で型を分岐しないため、version 4 も graceful degradation する。
- 古い MCP で version 4 文書を全置換しようとすると、`schemaVersion == 3` の検証と、未知 field を許さない
  decode-to-reencode の完全一致検証により拒否される。indent が黙って削除されて保存されることはない。
- 古いアプリでサマリーを再生成し、新しい version 3 文書として置換した場合は、元のネスト情報が失われる。この
  downgrade 後にネストを保持した編集や更新は保証しない。

DB migration が不要で既存文書を読み取れる変更ではあるが、LLM output schema と MCP contract が変わる。
したがって、[AGENTS.md](../../AGENTS.md) の Release Versioning に従い、次回のリリース準備では marketing version の
minor を上げて patch を 0 に戻す。実際の `CFBundleShortVersionString` と `CFBundleVersion` は本 ADR の追加時ではなく、
リリース準備時に更新する。

## Consequences

良い影響:

- 自己再帰なしの strict structured output のまま、3 階層の list と table を LLM 生成結果に保持できる。
- section / block id と平坦な読み順を維持するため、ADR-0018 の全体置換と既存 renderer の責務を保てる。
- LLM DTO の table cell を plain string に限定し、生成 token と schema の複雑さを抑えられる。
- LLM 生成 table を 1 block あたり最大 612、1 document あたり合計 1,200 描画 cells に制限し、非 lazy な SwiftUI
  `Grid` と各 renderer の workload を有界にできる。既存 AST / MCP table の参照形式と保存内容は変更しない。
- 新規生成の現行 version と MCP 書き込みの受理集合を `DahliaRuntimeSupport` に一元化し、アプリと MCP ヘルパーの
  version 判定が target ごとのリテラル重複でずれることを防げる。
- version 3 の既存文書は移行処理なしで読み取れ、indent 0 の省略により不要な CAS hash 差分を避けられる。
- LLM 出力と MCP 書き込みの信頼境界を分け、前者は正規化、後者は厳格拒否にできる。

コストとリスク:

- DTO、DTO-to-AST 変換、プロンプト、5 系統の renderer、MCP schema、MCP round-trip 検証、関連テストを同時に
  更新する実装コストがある。
- numbered list の階層別 counter と Share HTML の list stack は、単純な平坦 list より状態管理が増える。
- LLM が意味のない indent を多用する可能性がある。3 階層上限、飛び越し補正、先頭補正、プロンプトの使用条件で
  抑制する。
- 古いアプリでの読み取りは平坦表示へ劣化し、古いアプリによる再生成ではネストが失われる。
- 古い MCP は version 4 の更新を拒否するため、アプリと MCP helper の version が揃うまでネストを含む文書を
  書き換えられない。
- プロンプト調整後も provider ごとの indent と table の生成品質を観測し、乱用や不揃いがあれば例示を調整する必要がある。

実装時の回帰テストは、少なくとも次を固定する。

- 空 item を破棄した後に先頭と飛び越しを補正し、`0, blank 1, 2` が `0, 1` になること。
- provider が schema の table 上限を超えても、変換後が 1 block あたり 12 columns、50 body rows、最大 612 描画 cells、
  document 全体で最大 1,200 描画 cells に収まること。複数 table では読み順を保って body row を切り詰め、header が
  収まらない後続 table を破棄すること。
- `get_meeting` が version 2 の保存済み文書を返せる一方、`update_meeting_summary` は 3 / 4 以外、version 4 の
  blank list item、孤児または飛び越し indent を拒否すること。version 3 の blank item は legacy 互換のため受理すること。
- アプリと MCP ヘルパーが `DahliaRuntimeSupport` の同じ `current = 4` と受理集合 `{3, 4}` を参照し、target 内に
  schema version の判定リテラルを重複させないこと。
- Slack 向け share の HTML flavor と plain-text flavor の両方で擬似 indent が保持されること。

## Alternatives Considered

### 再帰コンテナを持つ Notion 型 block model

却下。任意の深さを表すには `$defs` と自己 `$ref` が必要であり、Codex app-server 経由で使う provider 間の対応が
揃わない。schema を受理する provider でも、モデルが深い再帰を安定生成するとは限らない。全 renderer も再帰 walk に
変わり、会議サマリーで必要な 3 階層に対して実装量が大きすぎる。

### item ごとの非再帰 `children` 配列

却下。1 段の `children` だけでは 3 階層を表現できない。3 段を別型で展開すると schema 自体のネストが深くなり、
同じ item の意味が階層ごとに別定義になる。

### 引用内 block と callout

却下。引用の中へ paragraph、list、table を入れるには再帰が必要で、Slack と RTF での表現も弱い。引用は引き続き
単一の `SummaryText` block とする。

### table cell を `{text, transcript_ref}` object にする

却下。plain string と比べて出力 token が概ね 2 倍になり、nested array 内での object 生成も不安定になりやすい。
表は俯瞰用途であり、cell 単位の文字起こし参照の需要は小さい。

### inline Markdown を bold / link の AST に分解する

却下。現行の inline Markdown string は `AttributedString` の parse と各出力先の変換で扱えている。inline AST を追加しても
今回必要な block hierarchy と table の問題は解決せず、DTO と renderer の複雑さだけが増える。

### heading 階層を増やして sections を廃止する

却下。section UUID は Google Docs の部分更新、Slack の分割投稿、MCP block 同一性を支える ADR-0001 と ADR-0018 の
前提である。sections は LLM 出力の骨格も安定させる。heading level の追加だけでは nested list も table も表現できない。
