import Darwin
import Foundation

/// Unix-socket helpers shared by Dahlia's local brokers.
public enum DahliaTokenBrokerProtocol {
    public static func socketURL(
        profile: DahliaRuntimeProfile,
        applicationSupportDirectory: URL = .applicationSupportDirectory
    ) -> URL {
        DahliaApplicationSupport.directoryURL(profile: profile, applicationSupportDirectory: applicationSupportDirectory)
            .appending(path: "TokenBroker", directoryHint: .isDirectory)
            .appending(path: "broker.sock")
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
