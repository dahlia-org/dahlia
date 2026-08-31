import Foundation
import Security

/// macOS Keychain への保存・読み込み・削除を行うラッパー。
/// エンタイトルメント付き署名済みビルドでは Data Protection Keychain を使用し、
/// 未署名ビルド（`swift run`）ではレガシーキーチェーンに自動フォールバックする。
///
/// - Note: Data Protection Keychain には Apple Developer 証明書での署名が必要。
///   ad-hoc 署名（`--sign -`）では `errSecMissingEntitlement` が返されるため、
///   自動的にレガシーキーチェーンにフォールバックする。
enum KeychainService {
    private static let serviceName = "com.dahlia.app"

    /// エンタイトルメントが無い環境で Data Protection Keychain を使うと返されるエラーコード。
    private static let fallbackErrors: Set<OSStatus> = [
        errSecMissingEntitlement, // -34018
        errSecInternalComponent, // -2070
    ]

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    // MARK: - Public API

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let status = upsertProtected(key: key, data: data)
        if status == errSecSuccess {
            _ = deleteLegacy(key: key)
            return
        }
        if !fallbackErrors.contains(status) {
            throw KeychainError.unexpectedStatus(status)
        }

        let legacyStatus = upsertLegacy(key: key, data: data)
        guard legacyStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(legacyStatus)
        }
    }

    static func load(key: String) -> String? {
        let (data, status) = loadProtected(key: key)
        if status == errSecSuccess, let data {
            return String(data: data, encoding: .utf8)
        }
        if status == errSecAuthFailed || status == errSecUserCanceled {
            return nil
        }
        // errSecItemNotFound または entitlement 不足なら legacy にフォールスルーする。

        let (legacyData, legacyStatus) = loadLegacy(key: key)
        if legacyStatus == errSecSuccess, let data = legacyData {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        deleteFromBothKeychains(key: key)
    }

    static func deleteOrThrow(key: String) throws {
        try validateDeletionStatuses(
            protectedStatus: deleteProtected(key: key),
            legacyStatus: deleteLegacy(key: key)
        )
    }

    static func validateDeletionStatuses(protectedStatus: OSStatus, legacyStatus: OSStatus) throws {
        let protectedSucceeded = protectedStatus == errSecSuccess
            || protectedStatus == errSecItemNotFound
            || fallbackErrors.contains(protectedStatus)
        guard protectedSucceeded else {
            throw KeychainError.unexpectedStatus(protectedStatus)
        }

        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(legacyStatus)
        }
    }

    // MARK: - Query Builders

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
    }

    // MARK: - Data Protection Keychain (Protected)

    private static func upsertProtected(key: String, data: Data) -> OSStatus {
        var updateQuery = baseQuery(key: key)
        updateQuery[kSecUseDataProtectionKeychain as String] = true
        let updateStatus = SecItemUpdate(
            updateQuery as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var query = baseQuery(key: key)
        query[kSecValueData as String] = data
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadProtected(key: String) -> (Data?, OSStatus) {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseDataProtectionKeychain as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (result as? Data, status)
    }

    private static func deleteProtected(key: String) -> OSStatus {
        var query = baseQuery(key: key)
        query[kSecUseDataProtectionKeychain as String] = true
        return SecItemDelete(query as CFDictionary)
    }

    // MARK: - Legacy Keychain (Fallback)

    private static func upsertLegacy(key: String, data: Data) -> OSStatus {
        let updateStatus = SecItemUpdate(
            baseQuery(key: key) as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var query = baseQuery(key: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadLegacy(key: String) -> (Data?, OSStatus) {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (result as? Data, status)
    }

    private static func deleteLegacy(key: String) -> OSStatus {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }

    // MARK: - Helpers

    @discardableResult
    private static func deleteFromBothKeychains(key: String) -> Bool {
        let protectedResult = deleteProtected(key: key)
        let legacyResult = deleteLegacy(key: key)
        return protectedResult == errSecSuccess || legacyResult == errSecSuccess
    }
}
