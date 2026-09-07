import DahliaRuntimeSupport
import SwiftUI

struct TextContentStatusView: View {
    let state: TextContentAvailability.State
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if state == .loading { ProgressView().controlSize(.mini) }
            Text(title).font(.caption).foregroundStyle(.secondary)
            if [.missing, .failed, .stale].contains(state) {
                Button(action: retry) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(L10n.retry)
                    .accessibilityLabel(L10n.retry)
            }
        }
        .help(title)
    }

    private var title: String {
        switch state {
        case .missing: L10n.textContentMissing
        case .loading: L10n.textContentLoading
        case .failed: L10n.textContentFailed
        case .ready: L10n.textContentReady
        case .stale: L10n.textContentStale
        case .empty: L10n.textContentEmpty
        case .deleted: L10n.textContentDeleted
        }
    }
}
