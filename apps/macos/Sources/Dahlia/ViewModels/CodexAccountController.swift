import Foundation
import Observation

/// Sign-in for one Local Account subscription through Pi's own OAuth flow. Each subscription signs in independently.
@MainActor
@Observable
final class CodexAccountController {
    let subscription: PiSubscription
    private(set) var accountStatus: PiRuntimeService.AccountStatus?
    private(set) var isCheckingStatus = false
    private(set) var isSigningIn = false
    private(set) var isSigningOut = false
    private(set) var errorMessage: String?

    private let service: PiRuntimeService
    private let urlOpener: any CodexLoginURLOpening

    init(
        subscription: PiSubscription,
        service: PiRuntimeService = .shared,
        urlOpener: any CodexLoginURLOpening = WorkspaceCodexLoginURLOpener()
    ) {
        self.subscription = subscription
        self.service = service
        self.urlOpener = urlOpener
    }

    var isBusy: Bool {
        isCheckingStatus || isSigningIn || isSigningOut
    }

    func activate() async {
        isCheckingStatus = true
        errorMessage = nil
        defer { isCheckingStatus = false }

        do {
            try Task.checkCancellation()
            accountStatus = try await service.accountStatus(for: subscription)
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

        do {
            try await service.signIn(subscription) { url in
                await self.openLoginURL(url)
            }
        } catch is CancellationError {
            // Cancelling the task closes Pi and its pending sign-in.
            isSigningIn = false
            return
        } catch {
            isSigningIn = false
            errorMessage = error.localizedDescription
            return
        }
        // Pi has saved the credential, so the new status is read even when the caller cancels from here on; otherwise
        // the saved sign-in would show as signed out until something else refreshed it.
        isSigningIn = false
        await Task { await activate() }.value
    }

    func signOut() async {
        guard !isBusy else { return }
        isSigningOut = true
        errorMessage = nil
        defer { isSigningOut = false }

        do {
            try await service.signOut(subscription)
            accountStatus = try await service.accountStatus(for: subscription)
        } catch is CancellationError {
            // SwiftUI cancels this operation when the settings screen disappears.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openLoginURL(_ url: URL) -> Bool {
        urlOpener.open(url)
    }
}
