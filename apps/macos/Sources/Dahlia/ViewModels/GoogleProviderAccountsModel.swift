import Combine
import Foundation
import Observation

@MainActor
@Observable
final class GoogleProviderAccountsModel {
    static let shared = GoogleProviderAccountsModel(publishesDirectory: true)
    private(set) var accounts: [GoogleProviderAccount] = []
    private(set) var controllers: [GoogleProviderAccountController] = []
    private(set) var errorMessage: String?
    private let worker: GoogleProviderAccountWorker
    private let publishesDirectory: Bool
    private let signInProvider: (@MainActor (UUID) -> any GoogleSignInProviding)?
    private var revision = 0
    private var observer: AnyCancellable?

    init(
        worker: GoogleProviderAccountWorker = GoogleProviderAccountWorker(),
        publishesDirectory: Bool = false,
        signInProvider: (@MainActor (UUID) -> any GoogleSignInProviding)? = nil
    ) {
        self.worker = worker
        self.publishesDirectory = publishesDirectory
        self.signInProvider = signInProvider
        observer = NotificationCenter.default.publisher(for: GoogleProviderAccount.didChange).sink { [weak self] _ in
            Task { await self?.activate() }
        }
    }

    func activate() async {
        revision += 1
        let revision = revision
        do {
            let accounts = try await worker.load()
            guard revision == self.revision else { return }
            self.accounts = accounts
            errorMessage = nil
            if publishesDirectory, ProviderAccountDirectory.setGoogleAccounts(accounts) {
                NotificationCenter.default.post(name: GoogleCalendarProvider.didChange, object: nil)
            }
        } catch {
            guard revision == self.revision else { return }
            errorMessage = error.localizedDescription
        }
        let pendingIDs = await worker.pendingDisconnectIDs()
        guard revision == self.revision else { return }
        let registeredIDs = Set(accounts.map(\.id))
        controllers = accounts.map { account in
            controllers.first { $0.id == account.id } ?? makeController(id: account.id, account: account)
        } + pendingIDs.filter { !registeredIDs.contains($0) }.map { id in
            controllers.first { $0.id == id } ?? makeController(id: id)
        }
    }

    func registrationController() -> GoogleProviderAccountController { makeController(id: .v7()) }

    private func makeController(id: UUID, account: GoogleProviderAccount? = nil) -> GoogleProviderAccountController {
        GoogleProviderAccountController(id: id, registeredAccount: account, signInProvider: signInProvider?(id), worker: worker)
    }
}
