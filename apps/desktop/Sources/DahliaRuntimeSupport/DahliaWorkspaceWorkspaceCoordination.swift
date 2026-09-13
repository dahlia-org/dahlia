import Darwin
import Foundation

public enum DahliaWorkspaceMutationLockError: LocalizedError {
    case busy

    public var errorDescription: String? {
        "Another Dahlia process is updating this workspace."
    }
}

/// Coordinates filesystem-plus-database workspace mutations across Dahlia and dahlia-mcp.
public enum DahliaWorkspaceMutationLock {
    public static func withLock<T>(
        workspaceURL: URL,
        workspaceID: UUID,
        operation: () throws -> T
    ) throws -> T {
        let lockURL = workspaceURL.appending(path: ".dahlia-project-\(workspaceID.uuidString).lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw DahliaWorkspaceMutationLockError.busy
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

public enum DahliaWorkspaceChangeNotification {
    private static let prefix = "com.dahlia.workspace.changed."

    public static func name(workspaceID: UUID) -> Notification.Name {
        Notification.Name(prefix + workspaceID.uuidString.lowercased())
    }

    public static func post(workspaceID: UUID, senderID: String? = nil) {
        DistributedNotificationCenter.default().postNotificationName(
            name(workspaceID: workspaceID),
            object: senderID,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

public enum DahliaWorkspaceFileIdentity: Hashable, Sendable {
    case file(device: UInt64, inode: UInt64)
    case normalizedPath(String)

    public static func resolve(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Self {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return .normalizedPath(DahliaProjectName.siblingKey(url.standardizedFileURL.path))
        }
        return .file(device: device, inode: inode)
    }
}

/// Moves one regular file below a Workspace without following replaceable parent-path symlinks.
public enum DahliaWorkspaceFileMover {
    public static func moveItem(
        at sourceURL: URL,
        to destinationURL: URL,
        inside workspaceURL: URL
    ) throws {
        let workspace = workspaceURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let sourceComponents = try relativeComponents(of: source, inside: workspace)
        let destinationComponents = try relativeComponents(of: destination, inside: workspace)
        guard let sourceName = sourceComponents.last,
              let destinationName = destinationComponents.last else {
            throw POSIXError(.EPERM)
        }
        let resolvedWorkspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        let sourceParent = try openDirectory(
            root: resolvedWorkspace,
            components: sourceComponents.dropLast()
        )
        defer { close(sourceParent) }
        let destinationParent = try openDirectory(
            root: resolvedWorkspace,
            components: destinationComponents.dropLast()
        )
        defer { close(destinationParent) }

        try moveRegularFile(
            sourceName: sourceName,
            sourceParent: sourceParent,
            destinationName: destinationName,
            destinationParent: destinationParent
        )
    }

    private static func moveRegularFile(
        sourceName: String,
        sourceParent: Int32,
        destinationName: String,
        destinationParent: Int32
    ) throws {
        try sourceName.withCString { sourcePointer in
            try destinationName.withCString { destinationPointer in
                var sourceStatus = stat()
                guard fstatat(sourceParent, sourcePointer, &sourceStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw currentPOSIXError()
                }
                guard sourceStatus.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EPERM) }

                var destinationStatus = stat()
                let destinationExists =
                    fstatat(destinationParent, destinationPointer, &destinationStatus, AT_SYMLINK_NOFOLLOW) == 0
                let flags: UInt32
                if destinationExists {
                    guard sourceStatus.st_dev == destinationStatus.st_dev,
                          sourceStatus.st_ino == destinationStatus.st_ino else {
                        throw POSIXError(.EEXIST)
                    }
                    flags = 0
                } else {
                    guard errno == ENOENT else { throw currentPOSIXError() }
                    flags = UInt32(RENAME_EXCL)
                }

                guard renameatx_np(
                    sourceParent,
                    sourcePointer,
                    destinationParent,
                    destinationPointer,
                    flags
                ) == 0 else {
                    throw currentPOSIXError()
                }

                var movedStatus = stat()
                guard fstatat(
                    destinationParent,
                    destinationPointer,
                    &movedStatus,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                    movedStatus.st_dev == sourceStatus.st_dev,
                    movedStatus.st_ino == sourceStatus.st_ino else {
                    _ = renameatx_np(
                        destinationParent,
                        destinationPointer,
                        sourceParent,
                        sourcePointer,
                        UInt32(RENAME_EXCL)
                    )
                    throw POSIXError(.EIO)
                }
            }
        }
    }

    private static func relativeComponents(
        of candidate: URL,
        inside workspace: URL
    ) throws -> [String] {
        let workspaceComponents = workspace.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.starts(with: workspaceComponents) else {
            throw POSIXError(.EPERM)
        }
        let components = candidateComponents.dropFirst(workspaceComponents.count)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw POSIXError(.EPERM)
        }
        return Array(components)
    }

    private static func openDirectory(
        root: URL,
        components: ArraySlice<String>
    ) throws -> Int32 {
        var descriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        for component in components {
            let nextDescriptor = component.withCString {
                openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                let error = currentPOSIXError()
                close(descriptor)
                throw error
            }
            close(descriptor)
            descriptor = nextDescriptor
        }
        return descriptor
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
