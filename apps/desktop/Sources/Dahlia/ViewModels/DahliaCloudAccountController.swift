import Foundation
import Observation

@MainActor
@Observable
final class DahliaCloudAccountController {
    static let shared = DahliaCloudAccountController()

    private(set) var account: DahliaCloudAccount?
    private(set) var connectionOrigin: String?
    private(set) var isRefreshing = false
    private(set) var isSigningIn = false
    private(set) var isSigningOut = false
    private(set) var errorMessage: String?

    let defaultConfiguration: DahliaCloudConfiguration?
    private let service: DahliaCloudService
    @ObservationIgnored private var accountTask: Task<Void, Never>?

    init(
        configuration: DahliaCloudConfiguration? = .current,
        service: DahliaCloudService? = nil
    ) {
        defaultConfiguration = configuration
        self.service = service ?? .shared
    }

    var isBusy: Bool { isRefreshing || isSigningIn || isSigningOut }

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
        guard !isBusy else { return }
        errorMessage = nil
        do {
            let connection = try await service.storedConnection()
            guard let connection else {
                account = nil
                connectionOrigin = nil
                return
            }
            isRefreshing = true
            defer { isRefreshing = false }
            _ = try await service.validAccessToken()
            account = connection.account
            connectionOrigin = connection.origin
        } catch is CancellationError {
            // SwiftUI cancels settings work when the view disappears.
        } catch {
            account = nil
            connectionOrigin = nil
            errorMessage = error.localizedDescription
        }
    }

    func signIn(configuration: DahliaCloudConfiguration) async {
        guard !isBusy else { return }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            account = try await service.signIn(configuration: configuration)
            connectionOrigin = configuration.origin
        } catch is CancellationError {
            // User cancelled browser sign-in or left the settings screen.
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
            try await service.signOut()
            account = nil
            connectionOrigin = nil
        } catch is CancellationError {
            // SwiftUI cancels settings work when the view disappears.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func startSignIn(configuration: DahliaCloudConfiguration) -> Task<Void, Never>? {
        startAccountTask { [weak self] in
            await self?.signIn(configuration: configuration)
        }
    }

    @discardableResult
    func startSignOut() -> Task<Void, Never>? {
        startAccountTask { [weak self] in
            await self?.signOut()
        }
    }

    func cancelAccountTask() {
        accountTask?.cancel()
    }

    private func startAccountTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard accountTask == nil, !isBusy else { return nil }
        let task = Task { [weak self] in
            await operation()
            self?.accountTask = nil
        }
        accountTask = task
        return task
    }
}
