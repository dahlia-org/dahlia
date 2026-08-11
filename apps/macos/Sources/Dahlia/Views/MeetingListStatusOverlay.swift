import SwiftUI

struct MeetingListStatusOverlay: View {
    let isLoaded: Bool
    let error: String?
    let isEmpty: Bool
    let isSearching: Bool
    let onRetry: () -> Void
    let onClearSearch: () -> Void

    var body: some View {
        if !isLoaded {
            ProgressView(isSearching ? L10n.searchingMeetings : L10n.loadingMeetings)
        } else if let error, isEmpty {
            ContentUnavailableView {
                Label(L10n.meetingListLoadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(L10n.retry, action: onRetry)
            }
        } else if isEmpty, isSearching {
            ContentUnavailableView {
                Label(L10n.noMeetingsMatchSearch, systemImage: "magnifyingglass")
            } description: {
                Text(L10n.adjustMeetingSearch)
            } actions: {
                Button(L10n.clearSearch, action: onClearSearch)
            }
        } else if isEmpty {
            ContentUnavailableView {
                Label(L10n.noMeetingsYet, systemImage: "waveform")
            } description: {
                Text(L10n.createFirstMeetingDescription)
            }
        }
    }
}
