import CoreServices
import Foundation

struct VaultFileSystemEventBatch {
    let directoryRenames: [(oldPath: String, newPath: String)]
    let newDirectories: [String]
    let removedDirectories: [String]
    let summaryRenames: [(oldPath: String, newPath: String)]
    let removedSummaryPaths: [String]

    init(paths: [String], flags: [UInt32], vaultURL: URL, fileManager: FileManager = .default) {
        let vaultPath = vaultURL.path + "/"
        var pendingDirectoryRenames: [(path: String, exists: Bool)] = []
        var pendingSummaryRenames: [(path: String, exists: Bool)] = []
        var newDirectories: [String] = []
        var removedDirectories: [String] = []
        var removedSummaryPaths: [String] = []

        for (path, flag) in zip(paths, flags) {
            guard let event = Self.classify(path: path, flag: flag, vaultPath: vaultPath, fileManager: fileManager) else { continue }
            switch event {
            case let .directoryRename(path, exists):
                pendingDirectoryRenames.append((path, exists))
            case let .directoryCreated(path):
                newDirectories.append(path)
            case let .directoryRemoved(path):
                removedDirectories.append(path)
            case let .summaryRename(path, exists):
                pendingSummaryRenames.append((path, exists))
            case let .summaryRemoved(path):
                removedSummaryPaths.append(path)
            }
        }

        let resolvedDirectoryRenames = Self.resolveRenames(pendingDirectoryRenames)
        let resolvedSummaryRenames = Self.resolveRenames(pendingSummaryRenames)
        directoryRenames = resolvedDirectoryRenames.renames
        self.newDirectories = newDirectories + resolvedDirectoryRenames.created
        self.removedDirectories = removedDirectories + resolvedDirectoryRenames.removed
        summaryRenames = resolvedSummaryRenames.renames
        self.removedSummaryPaths = removedSummaryPaths + resolvedSummaryRenames.removed
    }

    private static func classify(
        path: String,
        flag: UInt32,
        vaultPath: String,
        fileManager: FileManager
    ) -> Event? {
        guard path.hasPrefix(vaultPath) else { return nil }
        let relativePath = String(path.dropFirst(vaultPath.count))
        guard !relativePath.isEmpty else { return nil }

        let isDirectory = flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        if isDirectory {
            return classifyDirectory(path: path, relativePath: relativePath, flag: flag, fileManager: fileManager)
        }
        return classifyFile(path: path, relativePath: relativePath, flag: flag, fileManager: fileManager)
    }

    private static func classifyDirectory(
        path: String,
        relativePath: String,
        flag: UInt32,
        fileManager: FileManager
    ) -> Event? {
        let components = relativePath.split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") || $0.hasPrefix("_") }) else { return nil }

        let exists = fileManager.fileExists(atPath: path)
        if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            return .directoryRename(relativePath, exists: exists)
        }
        if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0, !exists {
            return .directoryRemoved(relativePath)
        }
        if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0, exists {
            return .directoryCreated(relativePath)
        }
        return nil
    }

    private static func classifyFile(
        path: String,
        relativePath: String,
        flag: UInt32,
        fileManager: FileManager
    ) -> Event? {
        let components = relativePath.split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") }),
              !components.contains("_dahlia"),
              URL(fileURLWithPath: relativePath).pathExtension.lowercased() == "md"
        else { return nil }

        let exists = fileManager.fileExists(atPath: path)
        let isRenamed = flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        let isRemoved = flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
        if isRenamed {
            return .summaryRename(relativePath, exists: exists)
        }
        if !exists, isRemoved {
            return .summaryRemoved(relativePath)
        }
        return nil
    }

    private static func resolveRenames(
        _ pendingRenames: [(path: String, exists: Bool)]
    ) -> (renames: [(oldPath: String, newPath: String)], created: [String], removed: [String]) {
        var renames: [(oldPath: String, newPath: String)] = []
        var created: [String] = []
        var removed: [String] = []
        var index = 0

        while index + 1 < pendingRenames.count {
            let first = pendingRenames[index]
            let second = pendingRenames[index + 1]
            if first.exists != second.exists {
                let oldPath = first.exists ? second.path : first.path
                let newPath = first.exists ? first.path : second.path
                renames.append((oldPath, newPath))
                index += 2
            } else {
                appendUnpairedRename(first, created: &created, removed: &removed)
                index += 1
            }
        }

        if index < pendingRenames.count {
            appendUnpairedRename(pendingRenames[index], created: &created, removed: &removed)
        }
        return (renames, created, removed)
    }

    private static func appendUnpairedRename(
        _ rename: (path: String, exists: Bool),
        created: inout [String],
        removed: inout [String]
    ) {
        if rename.exists {
            created.append(rename.path)
        } else {
            removed.append(rename.path)
        }
    }

    private enum Event {
        case directoryRename(String, exists: Bool)
        case directoryCreated(String)
        case directoryRemoved(String)
        case summaryRename(String, exists: Bool)
        case summaryRemoved(String)
    }
}
