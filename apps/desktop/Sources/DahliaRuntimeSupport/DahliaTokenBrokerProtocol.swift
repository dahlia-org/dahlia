import Darwin
import Foundation

public enum DahliaTokenBrokerProtocol {
    public enum Provider: String, Codable, Sendable { case databricks, dahlia }
    public struct Request: Codable, Sendable {
        public let connectionID: UUID
        public let provider: Provider

        public init(connectionID: UUID, provider: Provider = .dahlia) {
            self.connectionID = connectionID
            self.provider = provider
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
        DahliaApplicationSupport.directoryURL(profile: profile, applicationSupportDirectory: applicationSupportDirectory)
            .appending(path: "TokenBroker", directoryHint: .isDirectory)
            .appending(path: "broker.sock")
    }

    public static func requestToken(
        connectionID: UUID,
        provider: Provider = .dahlia,
        profile: DahliaRuntimeProfile
    ) throws -> String {
        try requestToken(
            connectionID: connectionID,
            provider: provider,
            profile: profile,
            applicationSupportDirectory: .applicationSupportDirectory
        )
    }

    public static func requestToken(
        connectionID: UUID,
        provider: Provider = .dahlia,
        profile: DahliaRuntimeProfile,
        applicationSupportDirectory: URL
    ) throws -> String {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 365, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw POSIXError(.ETIMEDOUT)
        }
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let socketURL = socketURL(profile: profile, applicationSupportDirectory: applicationSupportDirectory)
        var address = try unixAddress(path: socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, unixAddressLength(path: socketURL.path))
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED) }

        var payload = try JSONEncoder().encode(Request(connectionID: connectionID, provider: provider))
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
