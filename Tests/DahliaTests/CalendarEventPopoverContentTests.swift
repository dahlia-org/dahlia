import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarEventPopoverContentTests {
        @Test
        func longContentRendersAtStableSize() throws {
            let description = AttributedString(String(repeating: "Long calendar description https://example.com/agenda ", count: 100))
            let view = CalendarEventPopoverContent(
                title: String(repeating: "Long meeting title ", count: 20),
                dateText: "Jul 15, 2026 at 10:00 AM – 10:30 AM",
                attributedDescription: description
            )

            let image = try #require(ImageRenderer(content: view).nsImage)

            #expect(image.size == CGSize(width: 392, height: 312))
        }

        @Test
        func contentWithoutDescriptionRendersAtStableSize() throws {
            let view = CalendarEventPopoverContent(
                title: String(repeating: "Long meeting title ", count: 20),
                dateText: "Jul 15, 2026 at 10:00 AM – 10:30 AM",
                attributedDescription: nil
            )

            let image = try #require(ImageRenderer(content: view).nsImage)

            #expect(image.size == CGSize(width: 392, height: 152))
        }
    }
#endif
