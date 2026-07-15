import SwiftUI

struct CalendarEventPopoverContent: View {
    // Keep the popover's root size stable while presented. Content-driven window resizing can re-enter AppKit's display cycle.
    private static let contentWidth = 360.0
    private static let heightWithDescription = 280.0
    private static let heightWithoutDescription = 120.0

    let title: String
    let dateText: String
    let attributedDescription: AttributedString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "calendar")
                    .font(.headline)

                Text(dateText)
                    .foregroundStyle(.secondary)

                if let attributedDescription {
                    Divider()

                    Text(attributedDescription)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.contentWidth, height: contentHeight, alignment: .topLeading)
        .padding()
    }

    private var contentHeight: Double {
        attributedDescription == nil ? Self.heightWithoutDescription : Self.heightWithDescription
    }
}
