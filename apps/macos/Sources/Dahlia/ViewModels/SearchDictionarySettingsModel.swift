import DahliaMeetingAccess
import Foundation
import Observation

@MainActor
@Observable
final class SearchDictionarySettingsModel {
    var selectedDictionaryID = ""
    private(set) var configuration = SearchDictionaryConfiguration()
    private(set) var activeConfiguration = SearchDictionaryConfiguration()
    private(set) var neologdReleases: [SearchNeologdRelease] = []
    private(set) var installedNeologdIDs: Set<String> = []
    private(set) var isLoadingReleases = false
    private(set) var catalogError: String?
    private(set) var userDictionaryPath = ""
    private(set) var isUserDictionaryValid = false
    private(set) var isBusy = false
    private(set) var isLoaded = false
    private(set) var isDownloading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: SearchDictionaryService?
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(database: AppDatabaseManager?) {
        service = database.map { SearchDictionaryService(database: $0) }
    }

    var isAvailable: Bool { service != nil }
    var needsRebuild: Bool { configuration != activeConfiguration }
    var canRequestRebuild: Bool { isLoaded && !isBusy }

    func refresh() async {
        guard let service else { return }
        do {
            let snapshot = try await service.snapshot()
            apply(snapshot)
            isLoaded = true
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    var needsCompatibleDictionary: Bool {
        guard let path = activeConfiguration.dictionaryPath else { return false }
        return SearchNeologdRelease(directoryName: URL(filePath: path).lastPathComponent)?.version.hasPrefix("6.") != true
    }

    var activeDictionaryName: String {
        guard let path = activeConfiguration.dictionaryPath else { return L10n.searchDictionaryIPADIC }
        let version = SearchNeologdRelease(directoryName: URL(filePath: path).lastPathComponent)?.version
        return "IPADIC NEologd" + (version.map { " \($0)" } ?? "")
    }

    func refreshAvailableReleases(session: URLSession = .shared) async {
        guard let service, !isLoadingReleases else { return }
        isLoadingReleases = true
        defer { isLoadingReleases = false }
        do {
            try await service.refreshAvailableReleases(session: session)
            catalogError = nil
            let options = try await service.neologdOptions()
            neologdReleases = options.releases
            installedNeologdIDs = options.installedIDs
        } catch {
            if !Task.isCancelled { catalogError = L10n.searchNeologdCatalogUnavailable }
        }
    }

    func selectDictionary() {
        guard let service, !isBusy,
              selectedDictionaryID != (configuration.dictionaryPath.map { URL(filePath: $0).lastPathComponent } ?? "") else { return }
        let release = neologdReleases.first { $0.id == selectedDictionaryID }
        guard selectedDictionaryID.isEmpty || release != nil else { return }
        isDownloading = release.map { !installedNeologdIDs.contains($0.id) } ?? false
        run { try await service.selectNeologd(release) }
    }

    func importUserDictionary(_ url: URL) {
        guard let service else { return }
        run { try await service.importUserDictionary(from: url) }
    }

    func removeUserDictionary() {
        guard let service else { return }
        run { try await service.clearUserDictionary() }
    }

    func rebuildConfiguration() async throws -> SearchDictionaryConfiguration? {
        guard let service else { return nil }
        isBusy = true
        defer { isBusy = false }
        let snapshot = try await service.snapshot()
        apply(snapshot)
        guard snapshot.userDictionaryError == nil else { throw SearchDictionaryError.invalidUserDictionary }
        return needsRebuild ? configuration : nil
    }

    func reportError(_ error: any Error) { errorMessage = error.localizedDescription }

    private func apply(_ snapshot: SearchDictionarySnapshot) {
        configuration = snapshot.preferred
        activeConfiguration = snapshot.active
        neologdReleases = snapshot.neologdReleases
        installedNeologdIDs = snapshot.installedNeologdIDs
        selectedDictionaryID = configuration.dictionaryPath.map { URL(filePath: $0).lastPathComponent } ?? ""
        userDictionaryPath = snapshot.userDictionaryPath
        let wasInvalid = !isUserDictionaryValid
        isUserDictionaryValid = snapshot.userDictionaryError == nil
        if let error = snapshot.userDictionaryError {
            errorMessage = error
        } else if wasInvalid {
            errorMessage = nil
        }
    }

    func cancelDownload() async {
        let task = operation
        task?.cancel()
        await task?.value
    }

    private func run(_ action: @escaping @Sendable () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        operation = Task {
            defer {
                isBusy = false
                isDownloading = false
                operation = nil
            }
            do {
                try await action()
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            if Task.isCancelled {
                // GRDB cancels reads in a cancelled task; cleanup must reread the saved selection.
                await Task { await self.refresh() }.value
            } else {
                await refresh()
            }
        }
    }
}
