import CryptoKit
import DahliaLindera
import Foundation
import GRDB

public struct SearchDictionaryConfiguration: Equatable, Sendable {
    public var dictionaryPath: String?
    public var userDictionaryPath: String?
    public var userDictionaryName: String?

    public init(dictionaryPath: String? = nil, userDictionaryPath: String? = nil, userDictionaryName: String? = nil) {
        self.dictionaryPath = dictionaryPath
        self.userDictionaryPath = userDictionaryPath
        self.userDictionaryName = userDictionaryName
    }

    /// Installed files have content-addressed, immutable paths, shared by the app and Local MCP.
    public var configurationHash: String {
        guard dictionaryPath != nil || userDictionaryPath != nil else { return SearchFTS5Tokenizer.configurationHash }
        let identity = [SearchFTS5Tokenizer.configurationHash, dictionaryPath ?? "", userDictionaryPath ?? ""].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func read(in db: Database, preferred: Bool = false) throws -> Self {
        // Released migrations create FTS tables before the optional dictionary settings table exists.
        guard try db.tableExists("search_dictionary_configuration"),
              let row = try Row.fetchOne(db, sql: "SELECT * FROM search_dictionary_configuration WHERE id = ?", arguments: [preferred ? 2 : 1])
        else { return Self() }
        return Self(
            dictionaryPath: row["dictionaryPath"],
            userDictionaryPath: row["userDictionaryPath"],
            userDictionaryName: row["userDictionaryName"]
        )
    }

    public func validate() throws {
        let analyzer = try makeAnalyzer()
        dahlia_lindera_delete(analyzer)
    }

    public func prepare() throws -> PreparedSearchDictionary {
        try PreparedSearchDictionary(handle: makeAnalyzer())
    }

    func makeAnalyzer() throws -> UnsafeMutableRawPointer {
        var analyzer: UnsafeMutableRawPointer?
        let status = (dictionaryPath ?? "embedded://ipadic").withCString { dictionary in
            if let userDictionaryPath {
                return userDictionaryPath.withCString { userDictionary in
                    dahlia_lindera_create_with_dictionaries(dictionary, userDictionary, &analyzer)
                }
            }
            return dahlia_lindera_create_with_dictionaries(dictionary, nil, &analyzer)
        }
        guard status == DahliaLinderaStatusOK.rawValue, let analyzer else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "Unable to load search dictionary (Lindera \(status))")
        }
        return analyzer
    }
}
