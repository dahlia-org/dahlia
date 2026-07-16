import SwiftUI

struct CodexChatMeetingReferenceDetailView: View {
    let name: String
    let reference: CodexChatMeetingReference?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .bold()
                    .lineLimit(2)
                if let reference {
                    Text(reference.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
