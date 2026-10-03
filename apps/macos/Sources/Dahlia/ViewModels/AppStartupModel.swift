import DahliaRuntimeSupport
import Foundation
import Observation

/// Owns the launch task independently of the window's lifetime, including the quit barrier.
@Observable
@MainActor
final class AppStartupModel {
    enum Phase: Equatable, Sendable {
        case preparing, restoring, updating, loadingWorkspaces
    }

    enum State: Equatable {
        case working(Phase)
        case failed(details: String, canContinue: Bool)
        case ready
    }

    private(set) var state: State = .working(.preparing)
    private(set) var isTerminating = false
    private var task: Task<Void, Never>?
    private var canCancelStartup = false
    private var readyAction: (@MainActor () -> Void)?

    var isReady: Bool { state == .ready }

    func start(
        onReady: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async throws -> String?
    ) async {
        if let task {
            await task.value
            return
        }
        guard case .working = state, !isTerminating else { return }
        readyAction = onReady
        let task = Task { @MainActor in
            do {
                if let warning = try await operation() {
                    state = .failed(details: warning, canContinue: true)
                } else {
                    becomeReady()
                }
            } catch {
                readyAction = nil
                state = .failed(details: error.localizedDescription, canContinue: false)
            }
        }
        self.task = task
        await task.value
        self.task = nil
    }

    func show(_ phase: Phase) {
        guard case let .working(current) = state else { return }
        // A synchronous migration callback may arrive after database preparation completes.
        guard current != .loadingWorkspaces else { return }
        state = .working(phase)
    }

    func continueAfterWarning() {
        guard !isTerminating, case .failed(_, canContinue: true) = state else { return }
        becomeReady()
    }

    private func becomeReady() {
        state = .ready
        guard !isTerminating else { return }
        let action = readyAction
        readyAction = nil
        action?()
    }

    func prepareForTermination() async {
        isTerminating = true
        if canCancelStartup {
            task?.cancel()
            return // Shared token refresh may ignore cancellation; discovery must not delay shutdown.
        }
        await task?.value
    }

    /// Call only after durable preparation and installation of the service shutdown handler.
    func beginWorkspaceLoading() -> Bool {
        canCancelStartup = true
        return !isTerminating
    }

    func cancelTermination() {
        isTerminating = false
        if isReady { becomeReady() }
    }

    @concurrent
    static func prepareDatabase(
        applicationSupportURL: URL = DahliaApplicationSupport.currentDirectoryURL,
        databaseURL: URL = AppDatabaseManager.databaseURL,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> (AppDatabaseManager, BackupRestoreStartupOutcome) {
        let fileManager = FileManager.default
        let recoveryURL = databaseURL.deletingLastPathComponent()
            .appending(path: BackupRestoreStartupProcessor.recoveryFilename)
        if fileManager.fileExists(atPath: BackupService.pendingRestoreURL(applicationSupportURL: applicationSupportURL).path)
            || fileManager.fileExists(atPath: recoveryURL.path) {
            await onPhase(.restoring)
        }
        let outcome = BackupRestoreStartupProcessor.applyPendingRestore(
            applicationSupportURL: applicationSupportURL,
            databaseURL: databaseURL
        )
        // Never create/open a replacement DB while the original still awaits recovery.
        guard !fileManager.fileExists(atPath: recoveryURL.path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        await onPhase(.preparing)
        let existed = fileManager.fileExists(atPath: databaseURL.path)
        let onMigration: @Sendable () -> Void = {
            guard existed else { return }
            Task { @MainActor in onPhase(.updating) }
        }
        let database = if databaseURL == AppDatabaseManager.databaseURL {
            try AppDatabaseManager(onMigration: onMigration)
        } else {
            try AppDatabaseManager(path: databaseURL.path, enablesConcurrentSearch: true, onMigration: onMigration)
        }
        return (database, outcome)
    }

    static func restoreWarning(_ outcome: BackupRestoreStartupOutcome) -> String? {
        switch outcome {
        case .none:
            nil
        case let .failed(message):
            L10n.backupRestoreFailed(message)
        case let .completed(results):
            results.contains(where: { $0.error != nil })
                ? results.map(\.localizedMessage).joined(separator: "\n")
                : nil
        }
    }
}
