import SwiftUI

struct SyncProgressView: View {
    let connections: [DahliaAccountConnection]
    @State private var controller = DahliaCloudAccountController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.syncProgress).font(.headline).accessibilityAddTraits(.isHeader)
                if controller.syncProgressUnavailable {
                    Label(L10n.syncProgressUnavailable, systemImage: "exclamationmark.triangle")
                } else {
                    ForEach(connections) { connection in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(connection.displayName).font(.subheadline).foregroundStyle(.secondary)
                            if let progress = controller.syncProgress[connection.id] {
                                ForEach(progress.workspaces) { workspace in
                                    WorkspaceSyncProgressView(progress: workspace)
                                }
                            } else {
                                Label(L10n.syncFetching, systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 420)
    }
}

struct WorkspaceSyncProgressView: View {
    let progress: WorkspaceSyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.name).font(.body.bold())
            HStack(spacing: 6) {
                if progress.phase == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: progress.state.symbol).accessibilityHidden(true)
                }
                Text(progress.phase.title)
            }
            .font(.footnote)
            if progress.phase == .attention {
                Text(progress.state.title).font(.footnote).foregroundStyle(.secondary)
                if let errorCode = progress.errorCode {
                    LabeledContent(L10n.syncServerError, value: errorCode)
                        .textSelection(.enabled)
                }
            }
            if progress.phase != .preparing, progress.remaining > 0 {
                LabeledContent(L10n.syncMeetingContents, value: progress.meetings.formatted())
                LabeledContent(L10n.syncFiles, value: progress.files.formatted())
                LabeledContent(L10n.syncAttachments, value: progress.attachments.formatted())
                if progress.other > 0 {
                    LabeledContent(L10n.syncOtherChanges, value: progress.other.formatted())
                }
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension WorkspaceSyncProgress.Phase {
    var title: String {
        switch self {
        case .preparing: L10n.syncPreparing
        case .text: L10n.syncText
        case .attachments: L10n.syncTransferringAttachments
        case .fetching: L10n.syncFetching
        case .retrying: L10n.syncRetrying
        case .attention: L10n.syncAttention
        case .synced: L10n.syncSynced
        }
    }
}

extension AccountSyncProgress {
    var summary: String {
        switch state {
        case .synced: return L10n.syncSynced
        case .recovering: return L10n.workspaceSyncRecovering
        case .pending: break
        default: return L10n.syncAttention
        }
        if workspaces.contains(where: { $0.phase == .preparing }) { return L10n.syncPreparing }
        let title = workspaces.contains(where: { $0.phase == .retrying }) ? L10n.syncRetrying : L10n.syncSyncing
        return remaining > 0 ? "\(title) · \(String(format: L10n.syncRemainingFormat, remaining))" : L10n.syncFetching
    }
}
