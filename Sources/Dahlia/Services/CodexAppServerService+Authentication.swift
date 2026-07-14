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
        let info = error["codexErrorInfo"] ?? error["codex_error_info"]
        return info?.stringValue?.lowercased() == "unauthorized"
            || info?.objectValue?["type"]?.stringValue?.lowercased() == "unauthorized"
    }
}
