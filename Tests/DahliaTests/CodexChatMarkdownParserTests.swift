#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct CodexChatMarkdownParserTests {
        @Test func preservesParagraphsAndUnorderedListItems() throws {
            let authenticationDescription =
                "GCP環境でログインがループする問題を調査。`.com`エイリアスとGoogle Workspaceの`.jp` IDの不一致が原因候補となり、" +
                "過去事例を確認のうえ必要なら`.jp`で環境を作り直す方針です。"
            let pocDescription =
                "Salesforce上でJさんのContactとPOC用Business Subscriptionを作成。発行は承認・バックエンド処理待ちで、" +
                "招待メール到着後にJさんがログイン・初期設定を進める予定です。POCはPremium Tier、終了希望は8月末です。"
            let markdown = [
                "昨日（7月15日）の予定を確認します。",
                "",
                "昨日（7月15日）は、DeNA／Databricks関連で3件ありました。",
                "",
                "- **DeNA/Databricks DAIS Recap**（約1時間48分）  ",
                "  要約は未作成です。",
                "",
                "- **Databricks GCP環境のアカウント認証トラブル対応**（約46分）  ",
                "  \(authenticationDescription)",
                "",
                "- **DeNA向けE2アカウント／POC発行設定**（約14分）  ",
                "  \(pocDescription)",
            ].joined(separator: "\n")

            #expect(try CodexChatMarkdownParser.parse(markdown) == [
                .paragraph("昨日（7月15日）の予定を確認します。"),
                .paragraph("昨日（7月15日）は、DeNA／Databricks関連で3件ありました。"),
                .unorderedList([
                    "**DeNA/Databricks DAIS Recap**（約1時間48分）\n要約は未作成です。",
                    "**Databricks GCP環境のアカウント認証トラブル対応**（約46分）\n\(authenticationDescription)",
                    "**DeNA向けE2アカウント／POC発行設定**（約14分）\n\(pocDescription)",
                ]),
            ])
        }

        @Test func parsesCommonBlockMarkdownAndLineBreaks() throws {
            let markdown = [
                "## Heading",
                "soft",
                "line  ",
                "hard",
                "",
                "3. First",
                "7) Second",
                "",
                "> Quoted text",
                "",
                "```swift",
                "let value = 1",
                "```",
                "",
                "---",
            ].joined(separator: "\n")

            #expect(try CodexChatMarkdownParser.parse(markdown) == [
                .heading(level: 2, text: "Heading"),
                .paragraph("soft line\nhard"),
                .orderedList([
                    CodexChatMarkdownOrderedItem(marker: "3.", text: "First"),
                    CodexChatMarkdownOrderedItem(marker: "7)", text: "Second"),
                ]),
                .blockquote("Quoted text"),
                .code(language: "swift", text: "let value = 1"),
                .divider,
            ])
        }

        @Test func parsesIncompleteStreamingMarkdown() throws {
            let markdown = [
                "## Partial heading",
                "",
                "- **unfinished emphasis",
                "",
                "```swift",
                "let value = 1",
            ].joined(separator: "\n")

            #expect(try CodexChatMarkdownParser.parse(markdown) == [
                .heading(level: 2, text: "Partial heading"),
                .unorderedList(["**unfinished emphasis"]),
                .code(language: "swift", text: "let value = 1"),
            ])
        }

        @Test func parsesTableColumnsRowsAndAlignment() throws {
            let markdown = [
                "| Item | Status | Value |",
                "|:---|:---:|---:|",
                "| Markdown | Supported | 100 |",
                "| Table | In progress | 42 |",
            ].joined(separator: "\n")

            #expect(try CodexChatMarkdownParser.parse(markdown) == [
                .table(CodexChatMarkdownTable(
                    header: ["Item", "Status", "Value"],
                    rows: [
                        ["Markdown", "Supported", "100"],
                        ["Table", "In progress", "42"],
                    ],
                    alignments: [.left, .center, .right]
                )),
            ])
        }

        @Test func parsesSingleColumnTable() throws {
            let markdown = [
                "| Status |",
                "| --- |",
                "| Ready |",
            ].joined(separator: "\n")

            #expect(try CodexChatMarkdownParser.parse(markdown) == [
                .table(CodexChatMarkdownTable(
                    header: ["Status"],
                    rows: [["Ready"]],
                    alignments: [.left]
                )),
            ])
        }

        @Test func preservesEscapedPipeAtEndOfTableRow() throws {
            let markdown = [
                "First | Second",
                "--- | ---",
                "one | two \\|",
            ].joined(separator: "\n")

            #expect(try CodexChatMarkdownParser.parse(markdown) == [
                .table(CodexChatMarkdownTable(
                    header: ["First", "Second"],
                    rows: [["one", "two \\|"]],
                    alignments: [.left, .left]
                )),
            ])
        }

        @Test func parsesLargeStreamingList() throws {
            let markdown = (0 ..< 2000)
                .map { "- item \($0)" }
                .joined(separator: "\n")

            let blocks = try CodexChatMarkdownParser.parse(markdown)

            guard case let .unorderedList(items) = blocks.first else {
                Issue.record("Expected one unordered list")
                return
            }
            #expect(blocks.count == 1)
            #expect(items.count == 2000)
        }

        @Test func tracksTheUnstableTailSource() throws {
            let paragraph = try CodexChatMarkdownParser.parseTrackingUnstableTail("single paragraph")
            #expect(paragraph.stablePrefixBlockCount == 0)
            #expect(paragraph.reparseSource == "single paragraph")

            let multiple = try CodexChatMarkdownParser.parseTrackingUnstableTail("First\n\n# Heading\n")
            #expect(multiple.stablePrefixBlockCount == 1)
            #expect(multiple.reparseSource == "# Heading\n")

            let fence = try CodexChatMarkdownParser.parseTrackingUnstableTail("Intro\n\n```swift\nlet value = 1")
            #expect(fence.stablePrefixBlockCount == 1)
            #expect(fence.reparseSource == "```swift\nlet value = 1")

            let empty = try CodexChatMarkdownParser.parseTrackingUnstableTail("")
            #expect(empty.blocks.isEmpty)
            #expect(empty.stablePrefixBlockCount == 0)
            #expect(empty.reparseSource.isEmpty)
        }

        @Test func expandsTheUnstableTailAcrossADividerBoundary() throws {
            let result = try CodexChatMarkdownParser.parseTrackingUnstableTail("paragraph\n---")

            #expect(result.blocks == [.paragraph("paragraph"), .divider])
            #expect(result.stablePrefixBlockCount == 0)
            #expect(result.reparseSource == "paragraph\n---")
        }

        @Test func unstableTailReparseMatchesFullParseAtEveryStreamingSplit() throws {
            let documents = [
                "Paragraph soft\nline  \nhard\n\n# Heading\n\n- one\n- two",
                "Before\n\n```swift\nlet value = 1\n```\n\nAfter",
                "| Name | Value |\n| --- | ---: |\n| one | 1 |\n| two | 2 |",
                "paragraph\n---x",
                "```swift\nlet x = 1 ```",
                "First\r\nsecond\r\n\r\n# Heading",
                "First\rsecond\r\r# Heading",
                "# A | B\n--- | ---",
                "> A | B\n--- | ---",
                "- A | B\n--- | ---",
                "- one\n\n- two",
                "1. one\n\n2. two",
            ]

            for markdown in documents {
                let expected = try CodexChatMarkdownParser.parse(markdown)
                for splitIndex in markdown.indicesIncludingEnd {
                    let prefix = String(markdown[..<splitIndex])
                    let suffix = String(markdown[splitIndex...])
                    let partial = try CodexChatMarkdownParser.parseTrackingUnstableTail(prefix)
                    let reparsedTail = try CodexChatMarkdownParser.parse(partial.reparseSource + suffix)
                    let combined = Array(partial.blocks.prefix(partial.stablePrefixBlockCount)) + reparsedTail
                    #expect(combined == expected, "Mismatch at split \(markdown.distance(from: markdown.startIndex, to: splitIndex)) in \(markdown)")
                }
            }
        }

        @Test func boundarySensitiveStreamingSplitsMatchFullParse() throws {
            let cases = [
                ("```swift\nlet x ", "```"),
                ("```sw", "ift\nlet x = 1"),
                ("a ", " \nb"),
                ("paragraph\n---", "x"),
                ("first\r", "\nsecond"),
                ("# A | B\n--- | --", "-"),
                ("> A | B\n--- | --", "-"),
                ("- A | B\n--", "- | ---"),
                ("- one\n\n-", " two"),
                ("1. one\n\n2", ". two"),
            ]

            for (prefix, suffix) in cases {
                let partial = try CodexChatMarkdownParser.parseTrackingUnstableTail(prefix)
                let reparsedTail = try CodexChatMarkdownParser.parse(partial.reparseSource + suffix)
                let combined = Array(partial.blocks.prefix(partial.stablePrefixBlockCount))
                    + reparsedTail
                let expected = try CodexChatMarkdownParser.parse(prefix + suffix)
                #expect(combined == expected)
            }
        }
    }

    private extension String {
        var indicesIncludingEnd: [Index] {
            Array(indices) + [endIndex]
        }
    }
#endif
