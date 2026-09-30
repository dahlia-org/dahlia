import os

/// Local Instruments intervals only. Never attach content, domain IDs, paths or credentials.
/// LocalCommit minus DatabaseWrite exposes time waiting for the shared database queue.
enum SyncDiagnostics {
    private static let signposter = OSSignposter(subsystem: "com.dahlia", category: "SyncPriority")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
