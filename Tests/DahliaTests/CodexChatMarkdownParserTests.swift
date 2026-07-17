#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct CodexChatMarkdownParserTests {
        @Test func preservesParagraphsAndUnorderedListItems() {
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

            #expect(CodexChatMarkdownParser.parse(markdown) == [
                .paragraph("昨日（7月15日）の予定を確認します。"),
                .paragraph("昨日（7月15日）は、DeNA／Databricks関連で3件ありました。"),
                .unorderedList([
                    "**DeNA/Databricks DAIS Recap**（約1時間48分）\n要約は未作成です。",
                    "**Databricks GCP環境のアカウント認証トラブル対応**（約46分）\n\(authenticationDescription)",
                    "**DeNA向けE2アカウント／POC発行設定**（約14分）\n\(pocDescription)",
                ]),
            ])
        }

        @Test func parsesCommonBlockMarkdownAndLineBreaks() {
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

            #expect(CodexChatMarkdownParser.parse(markdown) == [
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
    }
#endif
