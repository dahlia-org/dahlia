import SwiftUI

struct CodexChatMeetingReferencePreviewBadge: View {
    let name: String
    let reference: CodexChatMeetingReference?
    @State private var isDetailPresented = false
    @State private var isHoverPresentation = false

    var body: some View {
        Button(action: showDetails) {
            CodexChatMeetingReferenceBadge(name: name)
        }
        .buttonStyle(.plain)
        .onHover(perform: showDetailsOnHover)
        .popover(isPresented: $isDetailPresented, arrowEdge: .bottom) {
            CodexChatMeetingReferenceDetailView(name: name, reference: reference)
        }
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(L10n.showMeetingReferenceDetails)
    }

    private var accessibilityValue: String {
        reference?.createdAt.formatted(
            .dateTime.year().month(.abbreviated).day().hour().minute()
        ) ?? L10n.meetingUnavailable
    }

    private func showDetails() {
        isHoverPresentation = false
        isDetailPresented = true
    }

    private func showDetailsOnHover(_ isHovering: Bool) {
        if isHovering {
            isHoverPresentation = true
            isDetailPresented = true
        } else if isHoverPresentation {
            isDetailPresented = false
        }
    }
}
