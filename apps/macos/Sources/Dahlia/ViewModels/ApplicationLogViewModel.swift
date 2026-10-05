import Foundation
import Observation

@MainActor
@Observable
final class ApplicationLogViewModel {
    private nonisolated static let maximumEntryCount = 2000
    private static let pollingInterval = Duration.seconds(1)

    typealias LogLoader = @Sendable () async throws -> [String]
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private(set) var logLines: [String]
    private(set) var errorMessage: String?
    private(set) var revision = 0

    private let loadLogs: LogLoader
    private let sleep: Sleeper
    private var isRefreshing = false

    init(
        logLines: [String] = [],
        loadLogs: @escaping LogLoader = ApplicationLogViewModel.loadFileLogs,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.logLines = Array(logLines.suffix(Self.maximumEntryCount))
        self.loadLogs = loadLogs
        self.sleep = sleep
    }

    var hasLogs: Bool {
        !logLines.isEmpty
    }

    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await sleep(Self.pollingInterval)
            } catch {
                return
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loadedLines = try await loadLogs()
            guard !Task.isCancelled else { return }
            let boundedLines = Array(loadedLines.suffix(Self.maximumEntryCount))
            if boundedLines != logLines {
                logLines = boundedLines
                revision &+= 1
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func text(matching query: String) -> String {
        let matchingLines = if query.isEmpty {
            logLines
        } else {
            logLines.filter { $0.localizedStandardContains(query) }
        }
        return matchingLines.joined(separator: "\n")
    }

    private nonisolated static func loadFileLogs() async -> [String] {
        await ApplicationLogFile.shared.recentLines(limit: maximumEntryCount)
    }
}
