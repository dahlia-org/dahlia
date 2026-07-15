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

    /// Data Protection Keychain が利用���能かのプロセスライフタイムキャッシュ。
    /// 初回操作で判定し、以降は無駄な LAContext 生成と IPC を省略する。
    /// 全呼び出しサイトが @MainActor 上のため、実質的にシングルスレッドアクセス。
    private nonisolated(unsafe) static var dataProtectionAvailable: Bool?

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    // MARK: - Public API

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // 既存アイテムを両方のキーチェーンから削除（マイグレーション対応）
        deleteFromBothKeychains(key: key)

        if dataProtectionAvailable != false {
            let status = saveProtected(key: key, data: data)
            if status == errSecSuccess {
                dataProtectionAvailable = true
                return
            }
            if fallbackErrors.contains(status) {
                dataProtectionAvailable = false
            } else {
                throw KeychainError.unexpectedStatus(status)
            }
        }

        let legacyStatus = saveLegacy(key: key, data: data)
        guard legacyStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(legacyStatus)
        }
    }

    static func load(key: String) -> String? {
        if dataProtectionAvailable != false {
            let (data, status) = loadProtected(key: key)
            if status == errSecSuccess, let data {
                dataProtectionAvailable = true
                return String(data: data, encoding: .utf8)
            }
            if status == errSecAuthFailed || status == errSecUserCanceled {
                return nil
            }
            if fallbackErrors.contains(status) {
                dataProtectionAvailable = false
            }
            // errSecItemNotFound: protected は利用可能だがアイテムが無い → legacy にフォールスルー
        }

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

    // MARK: - Query Builders

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]
    }

    // MARK: - Data Protection Keychain (Protected)

    private static func saveProtected(key: String, data: Data) -> OSStatus {
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

    private static func saveLegacy(key: String, data: Data) -> OSStatus {
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
