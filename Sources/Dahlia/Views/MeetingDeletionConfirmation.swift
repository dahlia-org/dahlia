import SwiftUI

struct MeetingDeletionRequest: Identifiable {
    let meetingIds: Set<UUID>
    let meetingName: String?

    var id: Set<UUID> { meetingIds }

    private var isSingleMeeting: Bool {
        meetingIds.count == 1
    }

    var title: String {
        if isSingleMeeting {
            L10n.deleteMeetingConfirmation(meetingName ?? L10n.newMeeting)
        } else {
            L10n.deleteMeetingsConfirmation(meetingIds.count)
        }
    }

    var message: String {
        isSingleMeeting ? L10n.deleteMeetingWarning : L10n.deleteMeetingsWarning(meetingIds.count)
    }

    var actionTitle: String {
        isSingleMeeting ? L10n.delete : L10n.deleteCount(meetingIds.count)
    }
}

private struct MeetingDeletionConfirmationModifier: ViewModifier {
    @Binding var request: MeetingDeletionRequest?
    let onDelete: (Set<UUID>) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            request?.title ?? "",
            isPresented: Binding(
                get: { request != nil },
                set: { if !$0 { request = nil } }
            ),
            titleVisibility: .visible,
            presenting: request
        ) { request in
            Button(request.actionTitle, role: .destructive) {
                onDelete(request.meetingIds)
                self.request = nil
            }
            Button(L10n.cancel, role: .cancel) {
                self.request = nil
            }
        } message: { request in
            Text(request.message)
        }
    }
}

extension View {
    func meetingDeletionConfirmation(
        request: Binding<MeetingDeletionRequest?>,
        onDelete: @escaping (Set<UUID>) -> Void
    ) -> some View {
        modifier(MeetingDeletionConfirmationModifier(request: request, onDelete: onDelete))
    }
}
