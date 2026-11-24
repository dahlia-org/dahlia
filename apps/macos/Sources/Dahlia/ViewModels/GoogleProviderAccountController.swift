import AppKit
import Observation

/// Manages the direct Google identity independently of the provider selected by Calendar or Drive.
@MainActor
@Observable
final class GoogleProviderAccountController {
    private(set) var account: GoogleCalendarAccount?
    private(set) var hasConnection = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var name: String?
    private let signInProvider: any GoogleSignInProviding
    private let defaults: UserDefaults
    private var revision = 0
    private var observer: GoogleAuthSessionObserver?

    init(signInProvider: any GoogleSignInProviding = GoogleSignInAdapter(), defaults: UserDefaults = .standard) {
        self.signInProvider = signInProvider
        self.defaults = defaults
        observer = GoogleAuthSessionObserver(notificationName: signInProvider.sessionDidChangeNotification) { [weak self] disconnected in
            guard let self else { return }
            if disconnected {
                revision += 1
                apply(nil)
                hasConnection = false
            } else if !isBusy {
                await activate()
            }
        }
    }

    var isConfigured: Bool { signInProvider.isConfigured }
    var displayName: String { name ?? account.map { "\(L10n.google) (\($0.email.nilIfBlank ?? $0.displayName))" } ?? L10n.google }

    func activate() async {
        guard !isBusy else { return }
        isBusy = true
        let revision = revision
        defer { isBusy = false }
        do {
            let hasConnection = await signInProvider.hasPreviousSignIn
            guard self.revision == revision else { return }
            self.hasConnection = hasConnection
            let session = hasConnection ? try await signInProvider.restorePreviousSignIn() : nil
            guard self.revision == revision else { return }
            apply(session?.account)
            errorMessage = nil
        } catch is CancellationError {
            // Leaving Settings cancels this read without signing out the saved provider.
        } catch {
            guard self.revision == revision else { return }
            apply(nil)
            errorMessage = error.localizedDescription
        }
    }

    func signIn(window: NSWindow? = nil) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        let revision = revision
        defer { isBusy = false }
        do {
            guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { throw GoogleSignInError.missingPresentingWindow }
            // Calendar and Drive request their own permissions when enabled; adding a provider needs identity only.
            let session = try await signInProvider.signIn(withPresentingWindow: window, requestedScopes: [])
            guard self.revision == revision else { return false }
            apply(session.account)
            hasConnection = true
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard self.revision == revision else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func disconnect() async {
        guard !isBusy else { return }
        revision += 1
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await signInProvider.disconnect()
            apply(nil)
            hasConnection = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ name: String) {
        guard let account else { return }
        self.name = name.nilIfBlank
        defaults.set(self.name, forKey: "googleProviderAccountName.\(account.id)")
    }

    private func apply(_ account: GoogleCalendarAccount?) {
        self.account = account
        name = account.flatMap { defaults.string(forKey: "googleProviderAccountName.\($0.id)")?.nilIfBlank }
    }
}
