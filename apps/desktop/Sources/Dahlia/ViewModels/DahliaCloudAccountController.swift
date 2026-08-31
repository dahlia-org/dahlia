import Foundation
import Observation

@MainActor
@Observable
final class DahliaCloudAccountController {
    private enum AccountOperation {
        case refreshing
        case signingIn
        case signingOut
    }

    static let shared = DahliaCloudAccountController()

    private(set) var account: DahliaCloudAccount?
    private(set) var connectionOrigin: String?
    private(set) var errorMessage: String?
    private var activeOperation: AccountOperation?

    let defaultConfiguration: DahliaCloudConfiguration?
    private let service: DahliaCloudService
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration = 0

    init(
        configuration: DahliaCloudConfiguration? = .current,
        service: DahliaCloudService? = nil
    ) {
        defaultConfiguration = configuration
        self.service = service ?? .shared
    }

    var isRefreshing: Bool { activeOperation == .refreshing }
    var isSigningIn: Bool { activeOperation == .signingIn }
    var isSigningOut: Bool { activeOperation == .signingOut }
    var isBusy: Bool { activeOperation != nil }

    var isConnectedToDahliaCloud: Bool {
        guard let connectionOrigin, let cloudOrigin = defaultConfiguration?.origin else { return false }
        return DahliaCloudService.sameOrigin(connectionOrigin, cloudOrigin)
    }

    var connectionServiceName: String? {
        guard account != nil else { return nil }
        if isConnectedToDahliaCloud { return L10n.dahliaCloud }
        return L10n.dahliaServer
    }

    var connectionStatus: String? {
        guard let account, let connectionServiceName else { return nil }
        return L10n.dahliaConnection(connectionServiceName, account.displayName)
    }

    var connectionDetail: String? {
        guard account != nil, !isConnectedToDahliaCloud, let connectionOrigin else { return nil }
        return "(\(connectionOrigin))"
    }

    var connectionSystemImage: String {
        isConnectedToDahliaCloud ? "icloud" : "xserve"
    }

    func activate() async {
        guard let generation = beginOperation(.refreshing) else { return }
        defer { finishOperation(generation) }
        do {
            let connection = try await service.storedConnection()
            guard isCurrentOperation(generation) else { return }
            guard let connection else {
                account = nil
                connectionOrigin = nil
                return
            }
            _ = try await service.validAccessToken()
            guard isCurrentOperation(generation) else { return }
            account = connection.account
            connectionOrigin = connection.origin
        } catch is CancellationError {
            // SwiftUI cancels settings work when the view disappears.
        } catch {
            guard isCurrentOperation(generation) else { return }
            account = nil
            connectionOrigin = nil
            errorMessage = error.localizedDescription
        }
    }

    private func signIn(configuration: DahliaCloudConfiguration, generation: Int) async {
        defer { finishOperation(generation) }
        do {
            let signedInAccount = try await service.signIn(configuration: configuration)
            guard isCurrentOperation(generation) else { return }
            account = signedInAccount
            connectionOrigin = configuration.origin
        } catch is CancellationError {
            // User cancelled browser sign-in or left the settings screen.
        } catch {
            guard isCurrentOperation(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func signOut(generation: Int) async {
        defer { finishOperation(generation) }
        do {
            try await service.signOut()
            guard isCurrentOperation(generation) else { return }
            account = nil
            connectionOrigin = nil
        } catch is CancellationError {
            // SwiftUI cancels settings work when the view disappears.
        } catch {
            guard isCurrentOperation(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func startSignIn(configuration: DahliaCloudConfiguration) -> Task<Void, Never>? {
        guard let generation = beginOperation(.signingIn) else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await signIn(configuration: configuration, generation: generation)
        }
        accountTask = task
        return task
    }

    @discardableResult
    func startSignOut() -> Task<Void, Never>? {
        guard let generation = beginOperation(.signingOut) else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await signOut(generation: generation)
        }
        accountTask = task
        return task
    }

    func cancelAccountTask() {
        accountTask?.cancel()
    }

    private func beginOperation(_ operation: AccountOperation) -> Int? {
        guard activeOperation == nil else { return nil }
        operationGeneration += 1
        activeOperation = operation
        errorMessage = nil
        return operationGeneration
    }

    private func isCurrentOperation(_ generation: Int) -> Bool {
        activeOperation != nil && operationGeneration == generation
    }

    private func finishOperation(_ generation: Int) {
        guard isCurrentOperation(generation) else { return }
        activeOperation = nil
        accountTask = nil
    }
}
