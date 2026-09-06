import SwiftUI

struct MeetingSyncStatusView: View {
    let state: MeetingSyncState

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(title)
            .accessibilityLabel(title)
    }

    private var title: String {
        switch state {
        case .local: L10n.meetingSyncLocalSaved
        case .pending: L10n.meetingSyncPending
        case .synced: L10n.meetingSyncSynced
        case .recovering: L10n.vaultSyncRecovering
        case .updateRequired: L10n.vaultSyncUpdateRequired
        case .blocked(.conflict): L10n.vaultSyncConflict
        case .blocked(.authorization): L10n.meetingSyncAuthorization
        case .blocked(.validation): L10n.meetingSyncValidation
        }
    }

    private var symbol: String {
        switch state {
        case .local: "internaldrive"
        case .pending, .recovering: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.icloud"
        case .updateRequired, .blocked: "exclamationmark.triangle"
        }
    }
}
