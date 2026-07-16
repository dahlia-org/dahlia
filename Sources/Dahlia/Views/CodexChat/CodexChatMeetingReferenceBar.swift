import SwiftUI

struct CodexChatMeetingReferenceBar: View {
    let referenceIDs: [UUID]
    let referencesByID: [UUID: CodexChatMeetingReference]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(referenceIDs, id: \.self) { id in
                    let reference = referencesByID[id]
                    let referenceName = reference?.name ?? L10n.meetingUnavailable
                    ZStack(alignment: .topTrailing) {
                        CodexChatMeetingReferencePreviewBadge(
                            name: referenceName,
                            reference: reference
                        )
                        Button(
                            L10n.removeMeetingReference(referenceName),
                            systemImage: "xmark.circle.fill"
                        ) {
                            onRemove(id)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                        .offset(x: 5, y: -5)
                        .help(L10n.removeMeetingReference(referenceName))
                    }
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }
}
