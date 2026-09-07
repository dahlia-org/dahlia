import CryptoKit
import Foundation

public enum TextContentError: String, Error, Codable, Sendable, LocalizedError {
    case unavailable, incomplete, stale, deleted, authorizationRequired, updateRequired, changed, integrityFailure

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The text is not available on this device. Connect to the server and retry."
        case .incomplete: "The complete text has not been downloaded."
        case .stale: "The saved text is an older version."
        case .deleted: "This content no longer exists."
        case .authorizationRequired: "Sign in to access this content."
        case .updateRequired: "Update the server to use partial text storage."
        case .changed: "The content changed during the operation. Retry."
        case .integrityFailure: "The downloaded text could not be verified."
        }
    }
}

public enum TextContentEntity: String, Codable, Sendable, CaseIterable {
    case summary, transcript, file
}

/// Wire v1: decimal UTF-8 byte length + ':' + bytes; nil is '-:'. See Server text-content.ts.
public struct TextContentDigest: Sendable {
    private var hash = SHA256()
    public private(set) var byteCount = 0

    public init() {}

    public mutating func add(_ value: String?, body: Bool = true) {
        let bytes = value.map { Data($0.utf8) }
        hash.update(data: Data((bytes.map { "\($0.count):" } ?? "-:").utf8))
        if let bytes { hash.update(data: bytes) }
        if body { byteCount += bytes?.count ?? 0 }
    }

    public func digestHex() -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
}

public struct TextContentManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let entity: TextContentEntity
    public let entityId: UUID
    public let revision: Int
    public let present: Bool
    public let count: Int
    public let byteCount: Int
    public let sha256: String
}

public struct TextContentAvailability: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case missing, loading, failed, ready, stale, empty, deleted }
    public let state: State
    public let revision: Int?
    public let latestRevision: Int?

    public init(state: State, revision: Int? = nil, latestRevision: Int? = nil) {
        self.state = state
        self.revision = revision
        self.latestRevision = latestRevision
    }
}
