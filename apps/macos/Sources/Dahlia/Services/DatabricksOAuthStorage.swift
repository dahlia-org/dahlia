import DahliaRuntimeSupport
import Foundation

struct DatabricksOAuthCredential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expirationDate: Date
    let tokenEndpoint: URL
}

struct DatabricksOAuthStorage: Sendable {
    var loadConnection: @Sendable () throws -> DatabricksConnection?
    var saveConnection: @Sendable (DatabricksConnection?) throws -> Void
    var loadCredential: @Sendable (UUID) throws -> DatabricksOAuthCredential?
    var saveCredential: @Sendable (UUID, DatabricksOAuthCredential) throws -> Void
    var deleteCredential: @Sendable (UUID) throws -> Void

    static func local(profile: DahliaRuntimeProfile = DahliaApplicationSupport.profile()) -> Self {
        let prefix = "databricksOAuth.\(profile.rawValue)"
        return Self(
            loadConnection: {
                guard let data = UserDefaults.standard.data(forKey: prefix + ".connection") else { return nil }
                return try JSONDecoder().decode(DatabricksConnection.self, from: data)
            },
            saveConnection: { connection in
                if let connection {
                    try UserDefaults.standard.set(JSONEncoder().encode(connection), forKey: prefix + ".connection")
                } else {
                    UserDefaults.standard.removeObject(forKey: prefix + ".connection")
                }
            },
            loadCredential: { id in
                guard let value = KeychainService.load(key: prefix + "." + id.uuidString) else { return nil }
                return try JSONDecoder().decode(DatabricksOAuthCredential.self, from: Data(value.utf8))
            },
            saveCredential: { id, credential in
                let data = try JSONEncoder().encode(credential)
                try KeychainService.save(key: prefix + "." + id.uuidString, value: String(decoding: data, as: UTF8.self))
            },
            deleteCredential: { id in
                try KeychainService.deleteOrThrow(key: prefix + "." + id.uuidString)
            }
        )
    }
}
