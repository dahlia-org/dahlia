import Foundation
import Observation

@MainActor
@Observable
final class CodexAccountController {
    private(set) var accountStatus: CodexAppServerService.AccountStatus?
    private(set) var isCheckingStatus = false
    private(set) var isSigningIn = false
    private(set) var isSigningOut = false
    private(set) var errorMessage: String?

    private let service: CodexAppServerService
    private let urlOpener: any CodexLoginURLOpening
    private let runtimeReadiness: @MainActor @Sendable () async -> Bool

    init(
        service: CodexAppServerService = .shared,
        urlOpener: any CodexLoginURLOpening = WorkspaceCodexLoginURLOpener(),
        runtimeReadiness: @escaping @MainActor @Sendable () async -> Bool = {
            await VaultAISettingsModel.shared.waitForRuntimeContext()
        }
    ) {
        self.service = service
        self.urlOpener = urlOpener
        self.runtimeReadiness = runtimeReadiness
    }

    var isBusy: Bool {
        isCheckingStatus || isSigningIn || isSigningOut
    }

    func activateChatGPTSubscription() async {
        isCheckingStatus = true
        errorMessage = nil
        defer { isCheckingStatus = false }

        do {
            try Task.checkCancellation()
            guard await runtimeReadiness() else { throw CodexConfigurationError.accountNotReady }
            accountStatus = try await service.accountStatus(forceRefresh: true)
            try Task.checkCancellation()
        } catch is CancellationError {
            // SwiftUI cancels this operation when the settings screen disappears.
        } catch {
            accountStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        guard !isBusy else { return }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            let session = try await service.startChatGPTLogin()
            if Task.isCancelled {
                let service = service
                Task { try? await service.cancelLogin(loginID: session.id) }
                throw CancellationError()
            }
            guard urlOpener.open(session.authorizationURL) else {
                try? await service.cancelLogin(loginID: session.id)
                throw CodexAppServerError.loginPageCouldNotOpen
            }
            try await service.waitForLoginCompletion(loginID: session.id)
            accountStatus = try await service.accountStatus(forceRefresh: true)
        } catch is CancellationError {
            // Cancelling the task also cancels the pending app-server login attempt.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        guard !isBusy else { return }
        isSigningOut = true
        errorMessage = nil
        defer { isSigningOut = false }

        do {
            try await service.logout()
            accountStatus = try await service.accountStatus(forceRefresh: true)
        } catch is CancellationError {
            // SwiftUI cancels this operation when the settings screen disappears.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
