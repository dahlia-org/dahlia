import SwiftUI

struct MeetingProjectListStatusOverlay: View {
    let isLoaded: Bool
    let error: String?
    let isEmpty: Bool
    let onRetry: () -> Void

    var body: some View {
        if !isLoaded {
            ProgressView()
        } else if let error {
            ContentUnavailableView {
                Label(L10n.meetingListLoadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(L10n.retry, action: onRetry)
            }
        } else if isEmpty {
            ContentUnavailableView(L10n.noMeetingsYet, systemImage: "waveform")
        }
    }
}
