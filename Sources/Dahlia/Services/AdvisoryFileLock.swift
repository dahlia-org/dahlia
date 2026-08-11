import Darwin
import Foundation

enum AdvisoryFileLockError: LocalizedError {
    case alreadyLocked
    case openFailed(Int32)
    case lockFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyLocked:
            L10n.anotherDahliaInstanceMessage
        case .openFailed, .lockFailed:
            L10n.recordingStorageUnavailable
        }
    }
}

/// An advisory lock whose file descriptor is retained for the entire ownership lifetime.
final class AdvisoryFileLock: Sendable {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func acquire(at url: URL) throws -> AdvisoryFileLock {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )

        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw AdvisoryFileLockError.openFailed(errno)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            let code = errno
            close(descriptor)
            throw AdvisoryFileLockError.openFailed(code)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw AdvisoryFileLockError.alreadyLocked
            }
            throw AdvisoryFileLockError.lockFailed(code)
        }
        return AdvisoryFileLock(fileDescriptor: descriptor)
    }
}
