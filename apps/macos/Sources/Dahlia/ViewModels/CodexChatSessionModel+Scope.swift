import Foundation
import GRDB

extension CodexChatSessionModel {
    var canSelectScope: Bool {
        isBoundToCurrentAccount && backendThreadID == nil && messages
            .isEmpty && !hasPendingGenerationWork && !isReleased && !isRestoring && pendingImagePreparationCount == 0
    }

    var scopeContextRevision: Int {
        (contextProvider as? CodexChatContextProvider)?.revision ?? 0
    }

    var scopeProjectID: UUID? {
        if backendThreadID == nil, hasSelectedProject { return selectedScopeProjectID }
        return scopeSnapshot?.projectID
    }

    var scopeProjectContext: CodexChatContext? {
        guard let project = scopeSnapshot?.projects.first(where: { $0.id == scopeProjectID }) else { return nil }
        return .project(id: project.id, name: project.name, description: project.description)
    }

    func selectedScopeContext() throws -> CodexChatContext? {
        guard let selectedScopeProjectID else { return nil }
        guard let project = scopeSnapshot?.projects.first(where: { $0.id == selectedScopeProjectID }) else {
            throw CodexChatContextError.selectedProjectUnavailable
        }
        return .project(id: project.id, name: project.name, description: project.description)
    }

    func observeScope(dbQueue: DatabaseQueue?) async {
        guard let dbQueue else { return }
        let accountID = accountID
        let threadID = backendThreadID
        do {
            // Existing threads always use their saved membership, independently of the selected meeting.
            let context = if threadID == nil, !hasSelectedProject, let workspaceID = contextWorkspaceID {
                try await contextProvider.currentContext(workspaceID: workspaceID)
            } else {
                nil as CodexChatContext?
            }
            let observation = ValueObservation.tracking { db in
                try CodexChatScopeSnapshot.fetch(accountID: accountID, threadID: threadID, context: context, in: db)
            }.removeDuplicates()
            for try await snapshot in observation.values(in: dbQueue) {
                try Task.checkCancellation()
                guard !isReleased, backendThreadID == threadID else { return }
                scopeSnapshot = snapshot
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, !isReleased, backendThreadID == threadID else { return }
            errorMessage = error.localizedDescription
        }
    }
}
