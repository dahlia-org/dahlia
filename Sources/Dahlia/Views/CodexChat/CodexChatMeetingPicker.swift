import SwiftUI

struct CodexChatMeetingPicker: View {
    let references: [CodexChatMeetingReference]
    let highlightedID: UUID?
    let onSelect: (CodexChatMeetingReference) -> Void
    @AccessibilityFocusState private var accessibilityFocusedMeetingID: UUID?

    var body: some View {
        Group {
            if references.isEmpty {
                ContentUnavailableView(
                    L10n.noMatchingMeetingReferences,
                    systemImage: "calendar.badge.exclamationmark"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(references) { reference in
                                Button {
                                    onSelect(reference)
                                } label: {
                                    CodexChatMeetingPickerRow(
                                        reference: reference,
                                        isHighlighted: reference.id == highlightedID
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(reference.id)
                                .accessibilityFocused(
                                    $accessibilityFocusedMeetingID,
                                    equals: reference.id
                                )
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlightedID) {
                        guard let highlightedID else { return }
                        proxy.scrollTo(highlightedID, anchor: .center)
                        accessibilityFocusedMeetingID = highlightedID
                    }
                    .onAppear {
                        accessibilityFocusedMeetingID = highlightedID
                    }
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 320, minHeight: 80, idealHeight: 260, maxHeight: 320)
        .accessibilityLabel(L10n.meetingReferences)
    }
}
