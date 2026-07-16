import SwiftUI

struct CodexChatMeetingPickerRow: View {
    let reference: CodexChatMeetingReference
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isHighlighted ? "chevron.right" : "calendar")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(reference.name)
                    .lineLimit(1)
                Text(reference.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
