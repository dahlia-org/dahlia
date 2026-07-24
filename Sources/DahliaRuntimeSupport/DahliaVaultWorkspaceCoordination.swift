import Darwin
import Foundation

public enum DahliaVaultMutationLockError: LocalizedError {
    case busy

    public var errorDescription: String? {
        "Another Dahlia process is updating this vault."
    }
}

/// Coordinates filesystem-plus-database workspace mutations across Dahlia and dahlia-mcp.
public enum DahliaVaultMutationLock {
    public static func withLock<T>(
        vaultURL: URL,
        vaultID: UUID,
        operation: () throws -> T
    ) throws -> T {
        let lockURL = vaultURL.appending(path: ".dahlia-project-\(vaultID.uuidString).lock")
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
            throw DahliaVaultMutationLockError.busy
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

public enum DahliaWorkspaceChangeNotification {
    private static let prefix = "com.dahlia.workspace.changed."

    public static func name(vaultID: UUID) -> Notification.Name {
        Notification.Name(prefix + vaultID.uuidString.lowercased())
    }

    public static func post(vaultID: UUID) {
        DistributedNotificationCenter.default().postNotificationName(
            name(vaultID: vaultID),
            object: nil,
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
