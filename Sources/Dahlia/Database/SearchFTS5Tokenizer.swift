import DahliaLindera
import Foundation
import GRDB

final class SearchFTS5Tokenizer: FTS5CustomTokenizer {
    static let name = SearchDocumentsMigration.analyzerVersion

    private var analyzer: UnsafeMutableRawPointer?

    init(db _: Database, arguments: [String]) throws {
        guard arguments.isEmpty else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "Search tokenizer accepts no arguments")
        }
        guard String(cString: dahlia_lindera_analyzer_version()) == Self.name,
              String(cString: dahlia_lindera_config_hash())
              == SearchDocumentsMigration.analyzerConfigurationHash
        else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "Search tokenizer version mismatch")
        }
    }

    deinit {
        dahlia_lindera_delete(analyzer)
    }

    func tokenize(
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

    static func register(in db: Database) throws {
        db.add(tokenizer: Self.self)
    }
}
