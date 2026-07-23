import Foundation

extension CodexAppServerService {
    nonisolated static func isAuthenticationRPCError(
        data: JSONValue?,
        message: String,
        method: String
    ) -> Bool {
        if let data = data?.objectValue {
            let requiresRelogin = data["action"]?.stringValue?.lowercased() == "relogin"
                || data["errorCode"]?.stringValue?.lowercased() == "auth"
                || data["statusCode"]?.intValue == 401
            if requiresRelogin { return true }
        }
        guard method.hasPrefix("account/") else { return false }
        let message = message.lowercased()
        return message.contains("not logged in")
            || message.contains("login required")
            || message.contains("sign in required")
            || message.contains("unauthorized")
    }

    nonisolated static func isAuthenticationTurnError(_ error: [String: JSONValue]?) -> Bool {
        guard let error else { return false }
        let authenticationInfo = error["codexErrorInfo"] ?? error["codex_error_info"]
        return authenticationInfo?.stringValue?.lowercased() == "unauthorized"
            || authenticationInfo?.objectValue?["type"]?.stringValue?.lowercased() == "unauthorized"
    }

    nonisolated static func isExpectedProviderAuthenticationTurnError(_ error: [String: JSONValue]?) -> Bool {
        guard let error,
              let rawMessage = error["message"]?.stringValue
        else { return false }

        // Databricks can return this expected credential diagnostic without
        // codexErrorInfo, so preserve it for the user without reporting it.
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard message.hasPrefix("unexpected status 401 unauthorized:") else { return false }
        return message.contains("credential was not sent or was of an unsupported type for this api.")
    }
}
