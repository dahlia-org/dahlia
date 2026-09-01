import Darwin
import Foundation

public enum DahliaTokenBrokerProtocol {
    public static let capabilityEnvironmentKey = "DAHLIA_TOKEN_BROKER_CAPABILITY"

    public struct Request: Codable, Sendable {
        public let connectionID: UUID
        public let capability: String

        public init(connectionID: UUID, capability: String) {
            self.connectionID = connectionID
            self.capability = capability
        }
    }

    public struct Response: Codable, Sendable {
        public let token: String?
        public let error: String?

        public init(token: String? = nil, error: String? = nil) {
            self.token = token
            self.error = error
        }
    }

    public static func socketURL(
        profile: DahliaRuntimeProfile,
        applicationSupportDirectory: URL = .applicationSupportDirectory
    ) -> URL {
        let environment = [DahliaApplicationSupport.profileEnvironmentKey: profile.rawValue]
        return DahliaApplicationSupport.directoryURL(
            applicationSupportDirectory: applicationSupportDirectory,
            environment: environment
        )
        .appending(path: "TokenBroker", directoryHint: .isDirectory)
        .appending(path: "broker.sock")
    }

    public static func requestToken(
        connectionID: UUID,
        profile: DahliaRuntimeProfile,
        capability: String
    ) throws -> String {
        try requestToken(
            connectionID: connectionID,
            profile: profile,
            capability: capability,
            applicationSupportDirectory: .applicationSupportDirectory
        )
    }

    public static func requestToken(
        connectionID: UUID,
        profile: DahliaRuntimeProfile,
        capability: String,
        applicationSupportDirectory: URL
    ) throws -> String {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }

        let socketURL = socketURL(profile: profile, applicationSupportDirectory: applicationSupportDirectory)
        var address = try unixAddress(path: socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, unixAddressLength(path: socketURL.path))
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED) }

        var payload = try JSONEncoder().encode(Request(connectionID: connectionID, capability: capability))
        payload.append(0x0A)
        try writeAll(payload, to: descriptor)
        let response = try JSONDecoder().decode(Response.self, from: readLine(from: descriptor))
        guard let token = response.token, !token.isEmpty else {
            throw NSError(
                domain: "app.dahlia.token-broker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: response.error ?? "Token broker failed"]
            )
        }
        return token
    }

    public static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    public static func unixAddressLength(path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }

    public static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: written), buffer.count - written)
                guard result > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                written += result
            }
        }
    }

    public static func readLine(from descriptor: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 64 * 1024 {
            let result = Darwin.read(descriptor, &byte, 1)
            guard result > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        throw POSIXError(.EMSGSIZE)
    }
}
