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
    private var revision = 0
    private var observer: AnyCancellable?

    init(worker: GoogleProviderAccountWorker = GoogleProviderAccountWorker(), publishesDirectory: Bool = false) {
        self.worker = worker
        self.publishesDirectory = publishesDirectory
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
            controllers = accounts.map { account in
                controllers.first { $0.id == account.id } ?? GoogleProviderAccountController(registeredAccount: account, worker: worker)
            }
            errorMessage = nil
            if publishesDirectory, ProviderAccountDirectory.setGoogleAccounts(accounts) {
                NotificationCenter.default.post(name: GoogleCalendarProvider.didChange, object: nil)
            }
        } catch {
            guard revision == self.revision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func registrationController() -> GoogleProviderAccountController { GoogleProviderAccountController(worker: worker) }
}
