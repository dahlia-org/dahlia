import Foundation

enum OAuthCallbackPage {
    private static let template: String = {
        guard let url = try? PiBundle.resourceURL("oauth-callback.html"),
              let html = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "<!doctype html><html lang=\"{{language}}\"><title>{{title}} · Dahlia</title><h1>{{title}}</h1><p>{{message}}</p></html>"
        }
        return html
    }()

    static func html(succeeded: Bool) -> String {
        let values = [
            "language": L10n.oauthCallbackLanguage,
            "state": succeeded ? "success" : "failure",
            "title": succeeded ? L10n.oauthCallbackReceived : L10n.oauthCallbackFailed,
            "message": succeeded ? L10n.oauthCallbackContinue : L10n.oauthCallbackRetry,
        ]
        return values.reduce(template) { html, entry in
            let escaped = entry.value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            return html.replacingOccurrences(of: "{{\(entry.key)}}", with: escaped)
        }
    }
}
