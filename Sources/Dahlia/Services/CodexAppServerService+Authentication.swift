import Foundation

extension CodexAppServerService {
    func prepareProviderAuthentication() async throws {
        guard !isShuttingDown else { throw CancellationError() }

        if let state = providerAuthenticationPreparationState, state.waiters.isEmpty {
            do {
                try await Self.waitCancellably(for: state.task)
            } catch {
                try Task.checkCancellation()
            }
            finishProviderAuthenticationPreparation(state.id)
            return try await prepareProviderAuthentication()
        }

        let waiterID = UUID()
        let preparationID: UUID
        let task: Task<Void, Error>
        if var state = providerAuthenticationPreparationState {
            state.waiters.insert(waiterID)
            providerAuthenticationPreparationState = state
            preparationID = state.id
            task = state.task
        } else {
            preparationID = UUID()
            let preparation = providerAuthenticationPreparation
            task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                let requiresReload = try await preparation { [self] in
                    await markProviderAuthenticationReloadRequired()
                }
                if requiresReload {
                    await markProviderAuthenticationReloadRequired()
                }
                if await providerAuthenticationReloadRequired {
                    try await reloadConfiguration()
                }
            }
            providerAuthenticationPreparationState = ProviderAuthenticationPreparationState(
                id: preparationID,
                task: task,
                waiters: [waiterID]
            )
            Task { [weak self] in
                _ = await task.result
                await self?.finishProviderAuthenticationPreparation(preparationID)
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await Self.waitCancellably(for: task)
            } onCancel: {
                Task { await self.cancelProviderAuthenticationWaiter(waiterID, preparationID: preparationID) }
            }
            finishProviderAuthenticationWaiter(waiterID, preparationID: preparationID)
            finishProviderAuthenticationPreparation(preparationID)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled {
                cancelProviderAuthenticationWaiter(waiterID, preparationID: preparationID)
            } else {
                finishProviderAuthenticationWaiter(waiterID, preparationID: preparationID)
                finishProviderAuthenticationPreparation(preparationID)
            }
            throw error
        }
    }

    nonisolated static func prepareConfiguredDatabricksAuthentication(
        authenticationMayChange: @Sendable () async -> Void
    ) async throws -> Bool {
        let profileName = await MainActor.run { () -> String? in
            let settings = AppSettings.shared
            guard settings.codexAccountProvider == .databricks,
                  settings.isCodexAccountConfigurationCurrent
            else { return nil }
            return settings.codexDatabricksProfile.nilIfBlank
        }
        guard let profileName else { return false }

        let result = try await DatabricksCLIClient().ensureAuthenticated(
            profileName: profileName,
            onBrowserLoginRequired: authenticationMayChange
        )
        return result == .browserLoginCompleted
    }

    func markProviderAuthenticationReloadRequired() {
        providerAuthenticationReloadRequired = true
    }

    private func cancelProviderAuthenticationWaiter(_ waiterID: UUID, preparationID: UUID) {
        guard var state = providerAuthenticationPreparationState,
              state.id == preparationID,
              state.waiters.remove(waiterID) != nil
        else { return }

        if state.waiters.isEmpty {
            state.task.cancel()
        }
        providerAuthenticationPreparationState = state
    }

    private func finishProviderAuthenticationWaiter(_ waiterID: UUID, preparationID: UUID) {
        guard var state = providerAuthenticationPreparationState,
              state.id == preparationID
        else { return }

        state.waiters.remove(waiterID)
        providerAuthenticationPreparationState = state
    }

    private func finishProviderAuthenticationPreparation(_ preparationID: UUID) {
        guard providerAuthenticationPreparationState?.id == preparationID else { return }
        providerAuthenticationPreparationState = nil
    }

    private nonisolated static func waitCancellably(for task: Task<Void, Error>) async throws {
        let waiter = ProviderAuthenticationPreparationWaiter()
        Task {
            let result = await task.result
            await waiter.finish(with: result)
        }
        try await waiter.wait()
    }

    nonisolated static func isAuthenticationRPCError(
        data: JSONValue?,
        message: String,
        method: String
    ) -> Bool {
        if let data = data?.objectValue {
            let requiresRelogin = data["action"]?.stringValue?.lowercased() == "relogin"
                || data["errorCode"]?.stringValue?.lowercased() == "auth"
                || data["statusCode"]?.intValue == 401
            if requiresRelogin { return true }
        }
        guard method.hasPrefix("account/") else { return false }
        let message = message.lowercased()
        return message.contains("not logged in")
            || message.contains("login required")
            || message.contains("sign in required")
            || message.contains("unauthorized")
    }

    nonisolated static func isAuthenticationTurnError(_ error: [String: JSONValue]?) -> Bool {
        guard let error else { return false }
        let authenticationInfo = error["codexErrorInfo"] ?? error["codex_error_info"]
        return authenticationInfo?.stringValue?.lowercased() == "unauthorized"
            || authenticationInfo?.objectValue?["type"]?.stringValue?.lowercased() == "unauthorized"
    }

    nonisolated static func isExpectedProviderAuthenticationTurnError(_ error: [String: JSONValue]?) -> Bool {
        guard let error,
              let rawMessage = error["message"]?.stringValue
        else { return false }

        // Databricks can return this expected credential diagnostic without
        // codexErrorInfo, so preserve it for the user without reporting it.
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard message.hasPrefix("unexpected status 401 unauthorized:") else { return false }
        return message.contains("credential was not sent or was of an unsupported type for this api.")
    }
}

private actor ProviderAuthenticationPreparationWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.finish(with: .failure(CancellationError())) }
        }
    }

    func finish(with result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
