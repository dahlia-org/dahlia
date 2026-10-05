import Foundation
import JavaScriptCore
import Security

/// Wire budgets shared with Server documents/core.ts and documents/model.ts.
enum DocumentLimits {
    static let stateBytes = 8 * 1024 * 1024
    static let encodedUpdateBytes = ((stateBytes + 2) / 3) * 4
    static let responseBytes = 32 * 1024 * 1024
}

struct DocumentBlock: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var text: String
}

struct DocumentCoreResult: Codable, Sendable {
    struct Projection: Codable, Sendable {
        var text: String
        var blocks: [DocumentBlock]
    }

    var checkpoint: String
    var vector: String
    var update: String
    var projection: Projection
    var removed: [DocumentBlock]
    var purged: Bool?
    var changed: Bool?
    var runtimeThrough: Int64?
    struct Batch: Codable, Sendable { var update: String?
        var through: Int64?
    }

    var batch: Batch?
}

struct DocumentCoreCommand: Encodable, Sendable {
    struct Pending: Encodable, Sendable { var sequence: Int64
        var update: String
    }

    struct Runtime: Encodable, Sendable {
        var key: String
        var baseline: String
        var entries: [Pending]
        var recoveryThrough: Int64?
        var after: Int64?
        var prerequisites: [String]?
        var draft: String?
        var action: String?
    }

    var pending: [Pending]?
    var checkpoint: String?
    var updates: [String]?
    var text: String?
    var vector: String?
    var purgeBefore: Double?
    var local: Bool?
    var lightweight: Bool?
    var sending: Bool?
    var runtime: Runtime?
}

enum DocumentCoreError: LocalizedError {
    case unavailable, invalidCommand, failed, unsupportedSchema, tooLarge, privateDataRequiresLocalCopy, editPreservedPrivately
    var errorDescription: String? {
        switch self {
        case .privateDataRequiresLocalCopy: L10n.documentKeepLocal
        case .unsupportedSchema: L10n.documentUnsupportedSchema
        case .tooLarge: L10n.documentTooLarge
        default: L10n.documentSaveFailed
        }
    }
}

/// The condition protects the mailbox only. JSContext/JSValue are created, used, and destroyed on one Thread.
final class DocumentCoreWorker: @unchecked Sendable {
    private struct Work: Sendable {
        var command: String
        var continuation: CheckedContinuation<String, any Error>
    }

    private let condition = NSCondition()
    private var mailbox: [Work] = []
    private var stopped = false
    private var thread: Thread?

    init() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "Dahlia.Documents"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    func process(_ command: DocumentCoreCommand) async throws -> DocumentCoreResult {
        let json = try String(decoding: JSONEncoder().encode(command), as: UTF8.self)
        let result: String = try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            if stopped {
                condition.unlock()
                continuation.resume(throwing: DocumentCoreError.unavailable)
                return
            }
            mailbox.append(Work(command: json, continuation: continuation))
            condition.signal()
            condition.unlock()
        }
        return try JSONDecoder().decode(DocumentCoreResult.self, from: Data(result.utf8))
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    private func run() {
        let context = JSContext()!
        let random: @convention(block) (Int) -> [UInt8]? = { count in
            guard (0 ... 65536).contains(count) else { return nil }
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
            return bytes
        }
        let encode: @convention(block) (String) -> [UInt8] = { Array($0.utf8) }
        let decode: @convention(block) ([UInt8]) -> String? = { String(bytes: $0, encoding: .utf8) }
        context.setObject(random, forKeyedSubscript: "hostRandom" as NSString)
        context.setObject(encode, forKeyedSubscript: "hostEncode" as NSString)
        context.setObject(decode, forKeyedSubscript: "hostDecode" as NSString)
        context.evaluateScript("""
        globalThis.crypto = {
          getRandomValues(array) {
            const bytes = hostRandom(array.byteLength);
            if (!bytes) throw new Error('random_unavailable');
            new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
            return array;
          },
          randomUUID() {
            const bytes = this.getRandomValues(new Uint8Array(16));
            bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
            const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
            return hex.slice(0,8)+'-'+hex.slice(8,12)+'-'+hex.slice(12,16)+'-'+hex.slice(16,20)+'-'+hex.slice(20);
          }
        };
        globalThis.TextEncoder = class {
          encode(text) { return new Uint8Array(hostEncode(text)); }
          encodeInto(text, destination) {
            const bytes = this.encode(text);
            if (bytes.length > destination.length) throw new Error('encoding_capacity');
            destination.set(bytes); return {read:text.length,written:bytes.length};
          }
        };
        globalThis.TextDecoder = class {
          decode(bytes) {
            const text = hostDecode(Array.from(bytes || []));
            if (text == null) throw new Error("invalid_utf8");
            return text;
          }
        };
        globalThis.console = { log(){}, warn(){}, error(){} };
        """)
        if let url = Bundle.appModule.url(forResource: "document-core", withExtension: "global.js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            context.evaluateScript(source)
        }
        let entry = context.objectForKeyedSubscript("DahliaDocuments")?.objectForKeyedSubscript("run")
        while true {
            condition.lock()
            while mailbox.isEmpty, !stopped {
                condition.wait()
            }
            if mailbox.isEmpty, stopped { condition.unlock()
                break
            }
            let work = mailbox.removeFirst()
            condition.unlock()
            autoreleasepool {
                context.exception = nil
                if let result = entry?.call(withArguments: [work.command]), context.exception == nil, let value = result.toString() {
                    work.continuation.resume(returning: value)
                } else {
                    let message = context.exception?.toString() ?? ""
                    let error: DocumentCoreError = message.contains("document_runtime_unavailable") ? .unavailable
                        : message.contains("unsupported_document_schema") ? .unsupportedSchema
                        : message.contains("document_too_large") ? .tooLarge : .failed
                    work.continuation.resume(throwing: error)
                }
            }
        }
    }
}
