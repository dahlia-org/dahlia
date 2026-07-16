import SwiftUI

struct CodexChatMeetingReferenceBar: View {
    let referenceIDs: [UUID]
    let name: (UUID) -> String
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(referenceIDs, id: \.self) { id in
                    let referenceName = name(id)
                    Button {
                        onRemove(id)
                    } label: {
                        Label(referenceName, systemImage: "calendar")
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                            .overlay(alignment: .trailing) {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                                    .offset(x: 5, y: -8)
                                    .accessibilityHidden(true)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(L10n.removeMeetingReference(referenceName))
                    .accessibilityLabel(L10n.removeMeetingReference(referenceName))
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }
}
