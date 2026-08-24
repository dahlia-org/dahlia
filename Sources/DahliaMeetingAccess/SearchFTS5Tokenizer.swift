import DahliaLindera
import Foundation
import GRDB

private final class DocumentTokenRangeContext {
    let priorities: [String: Int]
    var bestMatch: (priority: Int, byteRange: Range<Int>)?

    init(candidates: [String]) {
        var priorities: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() where priorities[candidate] == nil {
            priorities[candidate] = index
        }
        self.priorities = priorities
    }
}

public final class SearchFTS5Tokenizer: FTS5CustomTokenizer {
    public static let name = "dahlia_lindera_ipadic_v1"
    public static let configurationHash = "e4e5d5c88f88895432fe3ec7e98b00ee2f05ca9ff6d78b47dda780ba6f5f308c"

    private var analyzer: UnsafeMutableRawPointer?

    public init(db _: Database, arguments: [String]) throws {
        guard arguments.isEmpty else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "Search tokenizer accepts no arguments")
        }
        guard String(cString: dahlia_lindera_analyzer_version()) == Self.name,
              String(cString: dahlia_lindera_config_hash()) == Self.configurationHash
        else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "Search tokenizer version mismatch")
        }
    }

    deinit {
        dahlia_lindera_delete(analyzer)
    }

    public func tokenize(
        context: UnsafeMutableRawPointer?,
        tokenization _: FTS5Tokenization,
        pText: UnsafePointer<CChar>?,
        nText: Int32,
        tokenCallback: @escaping FTS5TokenCallback
    ) -> Int32 {
        guard nText >= 0, let context else { return 1 }
        if analyzer == nil, dahlia_lindera_create(&analyzer) != DahliaLinderaStatusOK.rawValue {
            return 1
        }

        struct CallbackContext {
            let sqliteContext: UnsafeMutableRawPointer
            let callback: FTS5TokenCallback
        }
        var callbackContext = CallbackContext(sqliteContext: context, callback: tokenCallback)
        return withUnsafeMutablePointer(to: &callbackContext) { callbackContextPointer in
            dahlia_lindera_tokenize(
                analyzer,
                pText.map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self) },
                UInt(nText),
                callbackContextPointer
            ) { rawContext, token, tokenLength, startOffset, endOffset in
                guard let rawContext, let token else { return 1 }
                let bridge = rawContext.assumingMemoryBound(to: CallbackContext.self).pointee
                return bridge.callback(
                    bridge.sqliteContext,
                    0,
                    UnsafeRawPointer(token).assumingMemoryBound(to: CChar.self),
                    Int32(tokenLength),
                    startOffset,
                    endOffset
                )
            }
        }
    }

    public static func register(in db: Database) throws {
        db.add(tokenizer: Self.self)
    }

    public static func queryTokens(for query: String, in db: Database) throws -> [String] {
        guard query.count >= 2 else { return [] }
        let tokenizer = try db.makeTokenizer(tokenizerDescriptor())
        return try Array(tokenizer.tokenize(query: query).prefix(16).map(\.token))
    }

    public static func quotedQueryToken(_ token: String, isPrefix: Bool) -> String {
        "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"\(isPrefix ? "*" : "")"
    }

    public static func firstDocumentTokenRange(
        in text: String,
        matching candidates: [String],
        using tokenizer: any FTS5Tokenizer
    ) throws -> Range<String.Index>? {
        let bytes = Array(text.utf8)
        let byteRange = try bytes.withUnsafeBufferPointer { buffer -> Range<Int>? in
            guard let address = buffer.baseAddress else { return nil }
            var context = DocumentTokenRangeContext(candidates: candidates)
            let code = withUnsafeMutablePointer(to: &context) { contextPointer in
                tokenizer.tokenize(
                    context: UnsafeMutableRawPointer(contextPointer),
                    tokenization: .document,
                    pText: UnsafeRawPointer(address).assumingMemoryBound(to: CChar.self),
                    nText: CInt(buffer.count)
                ) { rawContext, _, tokenBytes, tokenLength, startOffset, endOffset in
                    guard let rawContext, let tokenBytes,
                          let token = String(
                              data: Data(bytes: tokenBytes, count: Int(tokenLength)),
                              encoding: .utf8
                          ) else { return 0 }
                    let context = rawContext.assumingMemoryBound(to: DocumentTokenRangeContext.self).pointee
                    guard let priority = context.priorities[token],
                          priority < (context.bestMatch?.priority ?? .max) else { return 0 }
                    context.bestMatch = (priority, Int(startOffset) ..< Int(endOffset))
                    return 0
                }
            }
            guard code == 0 else { throw DatabaseError(resultCode: ResultCode(rawValue: code)) }
            return context.bestMatch?.byteRange
        }
        guard let byteRange else { return nil }
        let utf8 = text.utf8
        let lowerUTF8 = utf8.index(utf8.startIndex, offsetBy: byteRange.lowerBound)
        let upperUTF8 = utf8.index(utf8.startIndex, offsetBy: byteRange.upperBound)
        guard let lowerBound = lowerUTF8.samePosition(in: text),
              let upperBound = upperUTF8.samePosition(in: text) else { return nil }
        return lowerBound ..< upperBound
    }
}
