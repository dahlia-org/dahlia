@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MenuBarCalendarEventRowTests {
        @Test
        func descriptionKeepsHTMLLineBreaksAndDecodesEntities() {
            let description = "<p>Agenda &amp; notes</p><ul><li>Status&nbsp;update</li><li>Q3 &lt;plan&gt;</li></ul><br>  <br/>"

            #expect(MenuBarCalendarEventRow.descriptionText(description) == "Agenda & notes\nStatus update\nQ3 <plan>")
        }

        @Test
        func descriptionKeepsPlainTextAngleBracketsAndDropsTruncatedTag() {
            #expect(MenuBarCalendarEventRow.descriptionText("x < 5 and y > 3") == "x < 5 and y > 3")
            #expect(
                MenuBarCalendarEventRow.descriptionText("Join Teams<https://teams.microsoft.com/l/meetup-join/1> or <mailto:help@example.com>", maxWidth: 200)
                    == "Join Teams https://teams.microsoft.com/l/meetup-join/1 or mailto:help@example.com"
            )

            let truncatedInsideTag = "Agenda" + String(repeating: "<span></span>", count: 400)
            #expect(MenuBarCalendarEventRow.descriptionText(truncatedInsideTag) == "Agenda")
        }

        @Test
        func descriptionWrapsByDisplayWidthAndLimitsLines() {
            #expect(MenuBarCalendarEventRow.descriptionText("aaa bbb ccc", maxWidth: 7) == "aaa bbb\nccc")
            #expect(MenuBarCalendarEventRow.descriptionText("会議室の予約", maxWidth: 4) == "会議\n室の\n予約")
            #expect(MenuBarCalendarEventRow.descriptionText("abcdefghij", maxWidth: 4, maxLines: 2) == "abcd\nefgh…")
            #expect(MenuBarCalendarEventRow.descriptionText(" <div> </div> ") == nil)
        }
    }
#endif
