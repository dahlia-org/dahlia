import SwiftUI

struct MeetingSyncStatusView: View {
    let state: MeetingSyncState

    var body: some View {
        Label {
            Text(state.title)
        } icon: {
            Image(systemName: state.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(state == .synced ? Color.green : Color.secondary, Color.secondary)
        }
        .labelStyle(.iconOnly)
        .font(.caption)
        .foregroundStyle(.secondary)
        .dahliaHoverHelp(label: state.title)
        .accessibilityLabel(state.title)
    }

}

extension MeetingSyncState {
    var title: String {
        switch self {
        case .local: L10n.meetingSyncLocalSaved
        case .pending: L10n.meetingSyncPending
        case .synced: L10n.meetingSyncSynced
        case .recovering: L10n.vaultSyncRecovering
        case .updateRequired: L10n.vaultSyncUpdateRequired
        case .relocationPaused: L10n.meetingSyncRelocationPaused
        case .blocked(.conflict): L10n.vaultSyncConflict
        case .blocked(.authorization): L10n.meetingSyncAuthorization
        case .blocked(.validation): L10n.meetingSyncValidation
        }
    }

    var symbol: String {
        switch self {
        case .local: "internaldrive"
        case .pending, .recovering: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.icloud"
        case .updateRequired, .relocationPaused, .blocked: "exclamationmark.triangle"
        }
    }
}
