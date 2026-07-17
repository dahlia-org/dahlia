import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ApplicationLogViewModel {
    private static let maximumEntryCount = 2000
    private static let subsystem = "com.dahlia"

    private(set) var logLines: [String]
    private(set) var errorMessage: String?

    init(logLines: [String] = []) {
        self.logLines = logLines
    }

    var hasLogs: Bool {
        !logLines.isEmpty
    }

    func refresh() {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@", Self.subsystem)
            let entries = try store.getEntries(with: .reverse, matching: predicate)
            logLines = entries.lazy
                .compactMap { $0 as? OSLogEntryLog }
                .prefix(Self.maximumEntryCount)
                .map(Self.renderedLine)
                .reversed()
            errorMessage = nil
        } catch {
            logLines = []
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
