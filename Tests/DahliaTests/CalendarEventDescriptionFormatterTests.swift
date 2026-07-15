@preconcurrency import AppKit
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarEventDescriptionFormatterTests {
        @Test
        func rendersHTMLFormattingAndLinks() throws {
            let description = #"<b>Agenda</b><br><a href="https://example.com/docs">Open docs</a>"#

            let attributed = CalendarEventDescriptionFormatter.attributedString(from: description)

            #expect(String(attributed.characters) == "Agenda\nOpen docs")
            let link = try #require(attributed.runs.compactMap(\.link).first)
            #expect(link == URL(string: "https://example.com/docs"))
        }

        @Test
        func rendersComplexCalendarDescription() throws {
            let url = try #require(URL(
                string: "https://example.com/documents/long-calendar-event-link-for-wrapping-tests/edit#section=agenda"
            ))
            let urlString = url.absoluteString
            let description = [
                #"<b>Meeting Agenda</b><br><a href="\#(urlString)" target="_blank">\#(urlString)</a><br><br>"#,
                "【週次定例】毎週月曜日10:00-10:30   (*毎月1回は全体会議に変更)<br>",
                "【内　容】プロジェクトの進捗確認<br>",
                "【対象者】プロジェクトメンバー<br>",
                "【備　考】会議室で実施します。オンラインからも参加できます",
            ].joined()

            let attributed = CalendarEventDescriptionFormatter.attributedString(from: description)

            #expect(String(attributed.characters) == """
            Meeting Agenda
            \(urlString)

            【週次定例】毎週月曜日10:00-10:30   (*毎月1回は全体会議に変更)
            【内　容】プロジェクトの進捗確認
            【対象者】プロジェクトメンバー
            【備　考】会議室で実施します。オンラインからも参加できます
            """)
            let rendered = NSAttributedString(attributed)
            let agendaFont = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let hasAgendaFont = agendaFont != nil
            #expect(hasAgendaFont)
            guard let agendaFont else { return }
            let isAgendaBold = agendaFont.fontDescriptor.symbolicTraits.contains(.bold)
            #expect(isAgendaBold)
            let link = try #require(attributed.runs.compactMap(\.link).first)
            #expect(link == url)
        }

        @Test
        func detectsBareURLInHTML() throws {
            let description = #"Online meeting:<br>https://example.com/meet/abc-defg-hij"#

            let attributed = CalendarEventDescriptionFormatter.attributedString(from: description)

            let link = try #require(attributed.runs.compactMap(\.link).first)
            #expect(link == URL(string: "https://example.com/meet/abc-defg-hij"))
        }

        @Test
        func preservesPlainTextAndDetectsBareURL() throws {
            let description = "Agenda\nhttps://example.com/docs"

            let attributed = CalendarEventDescriptionFormatter.attributedString(from: description)

            #expect(String(attributed.characters) == description)
            let link = try #require(attributed.runs.compactMap(\.link).first)
            #expect(link == URL(string: "https://example.com/docs"))
        }

        @Test
        func preservesAngleBracketedPlainText() {
            let description = "Discuss <launch>\nAlice <alice@example.com>"

            let attributed = CalendarEventDescriptionFormatter.attributedString(from: description)

            #expect(String(attributed.characters) == description)
        }

        @Test
        func removesUnsupportedLinkSchemes() {
            let description = #"<a href="javascript:alert(1)">Unsafe</a>"#

            let attributed = CalendarEventDescriptionFormatter.attributedString(from: description)

            #expect(attributed.runs.allSatisfy { $0.link == nil })
        }
    }
#endif
