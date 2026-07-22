import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ApplicationLogViewModel {
    private nonisolated static let maximumEntryCount = 2000
    private static let pollingInterval = Duration.seconds(1)
    private nonisolated static let subsystem = "com.dahlia"

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
        loadLogs: @escaping LogLoader = ApplicationLogViewModel.loadCurrentProcessLogs,
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

    nonisolated static func renderedLine(_ entry: OSLogEntryLog) -> String {
        let timestamp = entry.date.formatted(.iso8601)
        return "\(timestamp) [\(levelName(entry.level))] [\(entry.category)] \(entry.composedMessage)"
    }

    private nonisolated static func loadCurrentProcessLogs() async throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", Self.subsystem)
        let entries = try store.getEntries(with: .reverse, matching: predicate)
        return entries.lazy
            .compactMap { $0 as? OSLogEntryLog }
            .prefix(Self.maximumEntryCount)
            .map(Self.renderedLine)
            .reversed()
    }

    private nonisolated static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .error: "ERROR"
        case .fault: "FAULT"
        case .undefined: "DEFAULT"
        @unknown default: "DEFAULT"
        }
    }
}
