import AppKit
import DahliaRuntimeSupport
import SwiftUI

enum SyncRecoveryAction: Hashable {
    case retryDiscovery(UUID)
    case retryPull(workspaceId: UUID, connectionId: UUID)
    case reauthenticate(UUID)
    case retryAuthorization(UUID)
    case acceptServer(workspaceId: UUID, lastTransactionId: UUID)
    case reapplyLocal(UUID)
    case retryValidation(UUID)
    case discardValidation(workspaceId: UUID, lastTransactionId: UUID)
    case retryRecording(UUID)
    case openServer(URL)
}

struct SyncProgressView: View {
    let connections: [DahliaAccountConnection]
    @State private var controller = DahliaCloudAccountController.shared
    @State private var workingAction: SyncRecoveryAction?
    @State private var pendingDiscard: PendingSyncDiscard?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(L10n.syncProgress).font(.headline).accessibilityAddTraits(.isHeader)
                if controller.syncProgressUnavailable {
                    Label(L10n.syncProgressUnavailable, systemImage: "exclamationmark.triangle")
                }
                if let actionError {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if let error = controller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if !controller.syncProgressUnavailable {
                    ForEach(connections) { connection in
                        account(connection)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 420)
        .confirmationDialog(
            pendingDiscard?.title ?? "",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDiscard {
                Button(pendingDiscard.buttonTitle, role: .destructive) {
                    let action = pendingDiscard.action
                    self.pendingDiscard = nil
                    execute(action)
                }
            }
            Button(L10n.cancel, role: .cancel) { pendingDiscard = nil }
        } message: {
            Text(pendingDiscard?.message ?? "")
        }
    }

    private func account(_ connection: DahliaAccountConnection) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            Text(connection.displayName).font(.subheadline).foregroundStyle(.secondary)
            if let progress = controller.syncProgress[connection.id] {
                if let issue = progress.discoveryIssue {
                    SyncIssueView(issue: issue)
                    recoveryButtons(for: issue, connection: connection, workspace: nil)
                }
                if progress.workspaces.isEmpty, progress.discoveryIssue == nil {
                    Label(L10n.syncSynced, systemImage: "checkmark.circle")
                }
                ForEach(progress.workspaces) { workspace in
                    WorkspaceSyncProgressView(
                        progress: workspace,
                        connection: connection,
                        isWorking: isBusy,
                        onAction: request,
                        onDestructive: requestDestructive
                    )
                }
            } else {
                Label(L10n.syncFetching, systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    @ViewBuilder
    private func recoveryButtons(
        for issue: SyncProgressIssue,
        connection: DahliaAccountConnection,
        workspace: WorkspaceSyncProgress?
    ) -> some View {
        let serverURL = SyncServerLink.url(
            origin: connection.origin,
            workspaceId: workspace?.id,
            target: issue.target
        )
        SyncRecoveryButtons(
            issue: issue,
            workspace: workspace,
            connectionId: connection.id,
            serverURL: serverURL,
            accessibilityContext: workspace?.name ?? connection.displayName,
            isDisabled: isBusy,
            onAction: request,
            onDestructive: requestDestructive
        )
    }

    private var isBusy: Bool {
        workingAction != nil || controller.isBusy
    }

    private func request(_ action: SyncRecoveryAction) {
        guard case let .openServer(url) = action else {
            execute(action)
            return
        }
        guard NSWorkspace.shared.open(url) else {
            actionError = L10n.syncOpenServerFailed
            return
        }
        actionError = nil
    }

    private func requestDestructive(
        _ action: SyncRecoveryAction,
        workspaceName: String,
        impact: SyncDiscardImpact
    ) {
        pendingDiscard = PendingSyncDiscard(action: action, workspaceName: workspaceName, impact: impact)
    }

    private func execute(_ action: SyncRecoveryAction) {
        guard workingAction == nil else { return }
        guard !controller.isBusy else {
            actionError = L10n.syncRecoveryBusy
            return
        }
        actionError = nil
        workingAction = action
        Task { @MainActor in
            defer { workingAction = nil }
            do {
                switch action {
                case let .retryDiscovery(connectionId):
                    try await controller.retryDiscovery(connectionID: connectionId)
                case let .retryPull(workspaceId, connectionId):
                    try await controller.retryPull(workspaceID: workspaceId, connectionID: connectionId)
                case let .reauthenticate(connectionId):
                    guard let task = controller.startReauthentication(connectionID: connectionId) else {
                        throw SyncRecoveryError.accountBusy
                    }
                    await task.value
                case let .retryAuthorization(connectionId):
                    try await controller.retryAuthorizationSync(connectionID: connectionId)
                case let .acceptServer(workspaceId, lastTransactionId):
                    try await controller.acceptServerSyncVersion(
                        workspaceID: workspaceId,
                        expectedLastTransactionID: lastTransactionId
                    )
                case let .reapplyLocal(workspaceId):
                    try await controller.reapplyLocalSyncVersion(workspaceID: workspaceId)
                case let .retryValidation(workspaceId):
                    try await controller.retryInvalidSyncTransaction(workspaceID: workspaceId)
                case let .discardValidation(workspaceId, lastTransactionId):
                    try await controller.discardInvalidSyncTransaction(
                        workspaceID: workspaceId,
                        expectedLastTransactionID: lastTransactionId
                    )
                case let .retryRecording(meetingId):
                    try await controller.retryRecordingArchive(meetingID: meetingId)
                case .openServer:
                    break
                }
            } catch is CancellationError {
                return
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private enum SyncRecoveryError: LocalizedError {
    case accountBusy

    var errorDescription: String? { L10n.syncRecoveryBusy }
}

struct WorkspaceSyncProgressView: View {
    let progress: WorkspaceSyncProgress
    var connection: DahliaAccountConnection?
    var isWorking = false
    var onAction: (SyncRecoveryAction) -> Void = { _ in }
    var onDestructive: (SyncRecoveryAction, String, SyncDiscardImpact) -> Void = { _, _, _ in }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
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
            if progress.state == .recovering || progress.state == .updateRequired || progress.state == .relocationPaused {
                Text(progress.state.title).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(progress.issues) { issue in
                SyncIssueView(issue: issue)
                if let connection {
                    SyncRecoveryButtons(
                        issue: issue,
                        workspace: progress,
                        connectionId: connection.id,
                        serverURL: SyncServerLink.url(origin: connection.origin, workspaceId: progress.id, target: issue.target),
                        accessibilityContext: progress.name,
                        isDisabled: isWorking,
                        onAction: onAction,
                        onDestructive: onDestructive
                    )
                }
            }
            if progress.phase == .retrying {
                if let code = progress.retryErrorCode {
                    LabeledContent(L10n.syncErrorCode, value: code).textSelection(.enabled)
                }
                if let retryAt = progress.retryAt {
                    LabeledContent(L10n.syncNextRetry, value: retryAt.formatted(.relative(presentation: .named)))
                }
                Text(L10n.syncRetryBackoffDescription).foregroundStyle(.secondary)
            }
            if progress.phase != .preparing, progress.remaining > 0 {
                LabeledContent(L10n.syncMeetingContents, value: progress.meetings.formatted())
                LabeledContent(L10n.syncFiles, value: progress.files.formatted())
                LabeledContent(L10n.syncAttachments, value: progress.attachments.formatted())
                if progress.other > 0 {
                    LabeledContent(L10n.syncOtherChanges, value: progress.other.formatted())
                }
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(progress.recordingArchiveFailures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.syncRecordingArchiveFailure(failure.meetingName)).font(.footnote)
                        if let code = failure.code {
                            LabeledContent(L10n.syncErrorCode, value: code).textSelection(.enabled)
                        }
                        Button(L10n.retry, systemImage: "arrow.clockwise") {
                            onAction(.retryRecording(failure.meetingId))
                        }
                        .buttonStyle(.dahlia())
                        .controlSize(.small)
                        .disabled(isWorking || !progress.allowsRecordingArchiveRetry)
                        .accessibilityLabel("\(L10n.retry): \(failure.meetingName)")
                    }
                }
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SyncIssueView: View {
    let issue: SyncProgressIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            if let status = issue.status {
                LabeledContent(L10n.syncHTTPStatus, value: "HTTP \(status)")
            }
            LabeledContent(L10n.syncErrorCode, value: issue.code).textSelection(.enabled)
            if let target = issue.target {
                LabeledContent(L10n.syncTargetRecord, value: target.displayName).textSelection(.enabled)
            }
        }
    }
}

private struct SyncRecoveryButtons: View {
    let issue: SyncProgressIssue
    let workspace: WorkspaceSyncProgress?
    let connectionId: UUID
    let serverURL: URL?
    let accessibilityContext: String
    let isDisabled: Bool
    let onAction: (SyncRecoveryAction) -> Void
    let onDestructive: (SyncRecoveryAction, String, SyncDiscardImpact) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if issue.status == 401 {
                actionButton(L10n.reauthenticate, "person.crop.circle.badge.exclamation", .reauthenticate(connectionId))
            } else if issue.status == 403 {
                serverButton
                switch issue.source {
                case .discovery:
                    actionButton(L10n.syncRetryAfterPermission, "arrow.clockwise", .retryDiscovery(connectionId))
                case .pull:
                    if let workspace {
                        actionButton(
                            L10n.syncRetryAfterPermission,
                            "arrow.clockwise",
                            .retryPull(workspaceId: workspace.id, connectionId: connectionId)
                        )
                    }
                case .queue:
                    actionButton(L10n.syncRetryAfterPermission, "arrow.clockwise", .retryAuthorization(connectionId))
                }
            } else {
                switch issue.source {
                case .discovery:
                    actionButton(L10n.retry, "arrow.clockwise", .retryDiscovery(connectionId))
                    serverButton
                case .pull:
                    if let workspace {
                        actionButton(
                            L10n.retry,
                            "arrow.clockwise",
                            .retryPull(workspaceId: workspace.id, connectionId: connectionId)
                        )
                    }
                    serverButton
                case .queue(.authorization):
                    actionButton(L10n.reauthenticate, "person.crop.circle.badge.exclamation", .reauthenticate(connectionId))
                case .queue(.conflict):
                    if let workspace, let impact = workspace.discardImpact {
                        destructiveButton(
                            L10n.useServerVersion,
                            "icloud.and.arrow.down",
                            .acceptServer(workspaceId: workspace.id, lastTransactionId: impact.lastTransactionId),
                            workspace,
                            impact
                        )
                    }
                    if let workspace, workspace.allowsCanonicalEdits {
                        actionButton(L10n.reapplyLocalVersion, "arrow.up.circle", .reapplyLocal(workspace.id))
                    }
                case .queue(.validation):
                    if let workspace {
                        actionButton(L10n.retry, "arrow.clockwise", .retryValidation(workspace.id))
                        if let impact = workspace.discardImpact {
                            destructiveButton(
                                L10n.syncDiscardFollowing,
                                "trash",
                                .discardValidation(workspaceId: workspace.id, lastTransactionId: impact.lastTransactionId),
                                workspace,
                                impact
                            )
                        }
                    }
                }
            }
        }
        .controlSize(.small)
    }

    private func actionButton(_ title: String, _ image: String, _ action: SyncRecoveryAction) -> some View {
        Button(title, systemImage: image) { onAction(action) }
            .buttonStyle(.dahlia())
            .disabled(isDisabled)
            .accessibilityLabel("\(title): \(accessibilityContext)")
    }

    @ViewBuilder
    private var serverButton: some View {
        if let serverURL {
            actionButton(issue.status == 403 ? L10n.syncCheckServer : L10n.syncOpenServer, "safari", .openServer(serverURL))
        }
    }

    private func destructiveButton(
        _ title: String,
        _ image: String,
        _ action: SyncRecoveryAction,
        _ workspace: WorkspaceSyncProgress,
        _ impact: SyncDiscardImpact
    ) -> some View {
        Button(title, systemImage: image, role: .destructive) {
            onDestructive(action, workspace.name, impact)
        }
        .buttonStyle(.dahlia(.destructive))
        .disabled(isDisabled)
        .accessibilityLabel("\(title): \(accessibilityContext)")
    }
}

private struct PendingSyncDiscard {
    let action: SyncRecoveryAction
    let workspaceName: String
    let impact: SyncDiscardImpact

    var title: String {
        switch action {
        case .acceptServer: L10n.syncUseServerConfirmation(workspaceName)
        default: L10n.syncDiscardConfirmation(workspaceName)
        }
    }

    var buttonTitle: String {
        switch action {
        case .acceptServer: L10n.useServerVersion
        default: L10n.syncDiscardFollowing
        }
    }

    var message: String {
        let impactDescription = L10n.syncDiscardImpact(
            transactions: impact.transactions,
            operations: impact.operations,
            records: impact.records,
            localBodies: impact.localBodies,
            meetings: impact.meetings
        )
        return "\(impactDescription)\n\n\(L10n.syncDiscardWarning)"
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
        if hasAttention { return L10n.syncAttention }
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

private extension SyncProgressIssue {
    var title: String {
        if status == 401 { return L10n.signInRequired }
        if status == 403 { return L10n.syncPermissionRequired }
        return switch source {
        case .discovery: L10n.syncDiscoveryFailed
        case .pull: L10n.syncPullFailed
        case .queue(.authorization): L10n.signInRequired
        case .queue(.conflict): L10n.workspaceSyncConflict
        case .queue(.validation): L10n.syncLocalValidationFailed
        }
    }
}

private extension SyncRecordTarget {
    var displayName: String {
        let value: (String, TypeID.Kind) = switch entity {
        case .workspace: (L10n.workspace, .workspace)
        case .project: (L10n.project, .project)
        case .meeting, .summary, .transcript: (L10n.syncMeeting, .meeting)
        case .file: (L10n.syncFile, .file)
        case .meetingAttachment: (L10n.syncAttachment, .attachment)
        case .recording: (L10n.syncRecording, .recording)
        case .meetingEvent: (L10n.syncEvent, .event)
        }
        return "\(value.0): \(TypeID.encode(id, as: value.1))"
    }
}
