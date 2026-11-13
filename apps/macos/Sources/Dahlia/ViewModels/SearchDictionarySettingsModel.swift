import DahliaMeetingAccess
import Foundation
import Observation

@MainActor
@Observable
final class SearchDictionarySettingsModel {
    var usesNeologd = false
    private(set) var configuration = SearchDictionaryConfiguration()
    private(set) var activeConfiguration = SearchDictionaryConfiguration()
    private(set) var neologdPath: String?
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

    func refresh() async {
        guard let service else { return }
        do {
            let snapshot = try await service.snapshot()
            configuration = snapshot.preferred
            activeConfiguration = snapshot.active
            neologdPath = snapshot.neologdPath
            usesNeologd = configuration.dictionaryPath != nil
            isLoaded = true
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    func selectDictionary() {
        guard let service, !isBusy, usesNeologd != (configuration.dictionaryPath != nil) else { return }
        var selected = configuration
        selected.dictionaryPath = usesNeologd ? neologdPath : nil
        run { [selected] in try await service.select(selected) }
    }

    func download() {
        guard let service, !isBusy else { return }
        isDownloading = true
        run { try await service.downloadNeologd() }
    }

    func importUserDictionary(_ url: URL) {
        guard let service else { return }
        run { try await service.importUserDictionary(from: url) }
    }

    func removeUserDictionary() {
        guard let service else { return }
        var selected = configuration
        selected.userDictionaryPath = nil
        selected.userDictionaryName = nil
        run { [selected] in try await service.select(selected) }
    }

    func reportImportError(_ error: any Error) { errorMessage = error.localizedDescription }

    func cancelDownload() { operation?.cancel() }

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
            await refresh()
        }
    }
}
