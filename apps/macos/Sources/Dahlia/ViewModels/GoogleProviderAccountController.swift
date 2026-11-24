import AppKit
import Observation

/// Manages one registered Google identity independently of Calendar's selected route.
@MainActor
@Observable
final class GoogleProviderAccountController: Identifiable {
    let id: UUID
    private(set) var account: GoogleCalendarAccount?
    private(set) var hasConnection = false
    private(set) var isDisconnectPending = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var name: String?
    private let signInProvider: any GoogleSignInProviding
    private let worker: GoogleProviderAccountWorker
    private var registeredAccount: GoogleProviderAccount?
    private var revision = 0
    private var observer: GoogleAuthSessionObserver?

    init(
        id: UUID = .v7(),
        registeredAccount: GoogleProviderAccount? = nil,
        signInProvider: (any GoogleSignInProviding)? = nil,
        worker: GoogleProviderAccountWorker = GoogleProviderAccountWorker()
    ) {
        self.id = registeredAccount?.id ?? id
        self.registeredAccount = registeredAccount
        self.worker = worker
        let provider = signInProvider ?? GoogleSignInAdapter(accountID: self.id, expectedAccountID: registeredAccount?.account.id)
        self.signInProvider = provider
        account = registeredAccount?.account
        name = registeredAccount?.name
        hasConnection = registeredAccount != nil || provider.isDisconnectPending
        isDisconnectPending = provider.isDisconnectPending
        observer = GoogleAuthSessionObserver(notificationName: provider.sessionDidChangeNotification) { [weak self] disconnected in
            guard let self else { return }
            if disconnected {
                revision += 1
                account = nil
                isDisconnectPending = provider.isDisconnectPending
                hasConnection = self.registeredAccount != nil || isDisconnectPending
            } else if !isBusy {
                await activate()
            }
        }
    }

    var isConfigured: Bool { signInProvider.isConfigured }
    var displayName: String {
        name ?? account.map { "\(L10n.google) (\($0.email.nilIfBlank ?? $0.displayName))" } ?? registeredAccount?.displayName ?? L10n.google
    }

    func activate() async {
        guard !isBusy else { return }
        isBusy = true
        let revision = revision
        defer { isBusy = false }
        do {
            let stored = try await worker.load().first { $0.id == id }
            guard self.revision == revision else { return }
            if let stored { registeredAccount = stored
                name = stored.name
            }
            let usable = await signInProvider.hasPreviousSignIn
            guard self.revision == revision else { return }
            isDisconnectPending = signInProvider.isDisconnectPending
            hasConnection = registeredAccount != nil || usable || isDisconnectPending
            let session = usable ? try await signInProvider.restorePreviousSignIn() : nil
            guard self.revision == revision else { return }
            account = session?.account
            errorMessage = nil
        } catch is CancellationError {
            // Leaving Settings does not remove a registered identity.
        } catch {
            guard self.revision == revision else { return }
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
            (signInProvider as? GoogleSignInAdapter)?.expectedAccountID = registeredAccount?.account.id
            let session = try await signInProvider.signIn(
                withPresentingWindow: window,
                requestedScopes: GoogleOAuthScope.calendar.union(GoogleOAuthScope.drive)
            )
            guard self.revision == revision else { return false }
            if let registeredAccount, registeredAccount.account.id != session.account.id { throw GoogleSignInError.accountMismatch }
            let record = GoogleProviderAccount(id: id, account: session.account, name: name)
            try await worker.save(record)
            guard self.revision == revision else { return false }
            registeredAccount = record
            account = session.account
            isDisconnectPending = false
            hasConnection = true
            NotificationCenter.default.post(name: GoogleProviderAccount.didChange, object: nil)
            return true
        } catch {
            if registeredAccount == nil {
                do { try await signInProvider.disconnect() } catch {
                    // The adapter's durable pending marker keeps this UUID discoverable after the modal closes.
                }
                isDisconnectPending = signInProvider.isDisconnectPending
                hasConnection = isDisconnectPending
                NotificationCenter.default.post(name: GoogleProviderAccount.didChange, object: nil)
            }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
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
            if registeredAccount != nil { try await worker.remove(id) }
            registeredAccount = nil
            account = nil
            name = nil
            isDisconnectPending = false
            hasConnection = false
            NotificationCenter.default.post(name: GoogleProviderAccount.didChange, object: nil)
        } catch {
            isDisconnectPending = signInProvider.isDisconnectPending
            hasConnection = registeredAccount != nil || hasConnection || isDisconnectPending
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ name: String) async {
        guard !isBusy, var record = registeredAccount else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            record.name = name.nilIfBlank
            try await worker.save(record)
            registeredAccount = record
            self.name = record.name
            NotificationCenter.default.post(name: GoogleProviderAccount.didChange, object: nil)
        } catch { errorMessage = error.localizedDescription }
    }
}
