import Darwin
import Foundation
import zlib

/// A streaming gzip/ustar container. Only regular files are accepted; paths are validated by BackupArchive.
final class BackupTarArchive {
    private let file: gzFile
    private let writing: Bool
    private var closed = false
    private var remaining: Int64 = 0
    private var entrySize: Int64 = 0

    init(url: URL, writing: Bool = false) throws {
        if writing {
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw BackupServiceError.invalidBackup }
            guard let stream = gzdopen(descriptor, "wb") else {
                Darwin.close(descriptor)
                throw BackupServiceError.invalidBackup
            }
            file = stream
        } else {
            guard let stream = gzopen(url.path, "rb") else { throw BackupServiceError.invalidBackup }
            file = stream
        }
        self.writing = writing
    }

    deinit { if !closed { gzclose(file) } }

    func close() throws {
        guard !closed else { return }
        if writing {
            try finishEntry()
            try write(Data(count: 1024))
        }
        closed = true
        guard gzclose(file) == Z_OK else { throw BackupServiceError.invalidBackup }
    }

    func writeHeader(path: String, size: Int64) throws {
        try finishEntry()
        guard path.utf8.count < 100, size >= 0 else { throw BackupServiceError.invalidBackup }
        var header = Data(count: 512)
        func put(_ value: String, at offset: Int) { header.replaceSubrange(offset ..< offset + value.utf8.count, with: value.utf8) }
        put(path, at: 0)
        put("0000600\0", at: 100)
        put("0000000\0", at: 108)
        put("0000000\0", at: 116)
        if size <= 0o777_7777_7777 {
            put(String(format: "%011llo", size) + "\0", at: 124)
        } else {
            header[124] = 0x80
            for index in 0 ..< 8 {
                header[135 - index] = UInt8(truncatingIfNeeded: size >> (index * 8))
            }
        }
        put("00000000000\0", at: 136)
        put("        ", at: 148)
        header[156] = 48
        put("ustar\0" + "00", at: 257)
        put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", at: 148)
        try write(header)
        remaining = size
        entrySize = size
    }

    func writeBlob(_ data: Data) throws {
        guard Int64(data.count) <= remaining else { throw BackupServiceError.invalidBackup }
        try write(data)
        remaining -= Int64(data.count)
    }

    func readHeader() throws -> (String, Int64)? {
        try finishEntry()
        let header = try read(512)
        if header.allSatisfy({ $0 == 0 }) {
            guard try read(512).allSatisfy({ $0 == 0 }) else { throw BackupServiceError.invalidBackup }
            // Consume the gzip footer too, so truncated streams and bad gzip checksums fail verification.
            var buffer = [UInt8](repeating: 0, count: 512)
            while true {
                let count = gzread(file, &buffer, UInt32(buffer.count))
                guard count >= 0 else { throw BackupServiceError.invalidBackup }
                if count == 0 {
                    var status: Int32 = 0
                    gzerror(file, &status)
                    guard status == Z_OK || status == Z_STREAM_END else { throw BackupServiceError.invalidBackup }
                    break
                }
                guard buffer.prefix(Int(count)).allSatisfy({ $0 == 0 }) else { throw BackupServiceError.invalidBackup }
            }
            return nil
        }
        func string(_ start: Int, _ length: Int) -> String {
            String(decoding: header[start ..< start + length].prefix { $0 != 0 }, as: UTF8.self)
        }
        let checksum = Int(string(148, 8).trimmingCharacters(in: .whitespaces), radix: 8)
        var checked = header
        checked.replaceSubrange(148 ..< 156, with: repeatElement(UInt8(32), count: 8))
        guard checksum == checked.reduce(0, { $0 + Int($1) }), header[156] == 48 || header[156] == 0,
              string(257, 6) == "ustar", header[345 ..< 500].allSatisfy({ $0 == 0 }),
              header[157 ..< 257].allSatisfy({ $0 == 0 }) else { throw BackupServiceError.invalidBackup }
        let size: Int64
        if header[124] == 0x80 {
            guard header[125 ..< 128].allSatisfy({ $0 == 0 }), header[128] < 0x80 else { throw BackupServiceError.invalidBackup }
            size = header[128 ..< 136].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
        } else {
            guard let parsed = Int64(string(124, 12).trimmingCharacters(in: .whitespaces), radix: 8), parsed >= 0 else {
                throw BackupServiceError.invalidBackup
            }
            size = parsed
        }
        remaining = size
        entrySize = size
        return (string(0, 100), size)
    }

    func readBlob(count: Int) throws -> Data {
        guard Int64(count) <= remaining else { throw BackupServiceError.invalidBackup }
        let data = try read(count)
        remaining -= Int64(count)
        return data
    }

    private func finishEntry() throws {
        guard remaining == 0 else { throw BackupServiceError.invalidBackup }
        let padding = Int((512 - entrySize % 512) % 512)
        if padding > 0 {
            if writing { try write(Data(count: padding)) } else {
                guard try read(padding).allSatisfy({ $0 == 0 }) else { throw BackupServiceError.invalidBackup }
            }
        }
        entrySize = 0
    }

    private func write(_ data: Data) throws {
        let count = data.withUnsafeBytes { gzwrite(file, $0.baseAddress, UInt32($0.count)) }
        guard count == data.count else { throw BackupServiceError.invalidBackup }
    }

    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes {
                gzread(file, $0.baseAddress?.advanced(by: offset), UInt32(count - offset))
            }
            guard received > 0 else { throw BackupServiceError.invalidBackup }
            offset += Int(received)
        }
        return data
    }
}
