import Foundation
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
        func detectsBareURLInHTML() throws {
            let description = #"Google Meet に参加:<br>https://meet.google.com/zun-tfvn-pcr"#

            let attributed = CalendarEventDescriptionFormatter.attributedString(from: description)

            let link = try #require(attributed.runs.compactMap(\.link).first)
            #expect(link == URL(string: "https://meet.google.com/zun-tfvn-pcr"))
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
