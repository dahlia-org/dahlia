import Foundation

public enum CustomerIdentityNormalizer {
    public static func email(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 254,
              trimmed.unicodeScalars.allSatisfy(\.isPrintableASCII)
        else {
            return nil
        }

        let components = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let localPart = String(components[0]).lowercased()
        guard isValidLocalPart(localPart),
              let domain = domainName(String(components[1]))
        else {
            return nil
        }
        return "\(localPart)@\(domain)"
    }

    public static func domainName(fromEmail email: String) -> String? {
        guard let canonicalEmail = self.email(email),
              let separator = canonicalEmail.lastIndex(of: "@")
        else {
            return nil
        }
        return String(canonicalEmail[canonicalEmail.index(after: separator)...])
    }

    public static func domainName(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.last == "." {
            value.removeLast()
        }
        guard !value.isEmpty,
              value.utf8.count <= 253,
              value.unicodeScalars.allSatisfy(\.isPrintableASCII),
              !value.contains("@"),
              !value.contains("/"),
              !value.contains(":")
        else {
            return nil
        }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty
                      && label.utf8.count <= 63
                      && label.first != "-"
                      && label.last != "-"
                      && label.allSatisfy(\.isASCIIDomainCharacter)
              })
        else {
            return nil
        }
        return value
    }

    public static func displayName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func organizationName(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func relationLabel(_ rawValue: String?) -> String {
        rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public static func isAutomaticOrganizationDomain(_ domainName: String) -> Bool {
        !publicEmailDomains.contains(domainName)
    }

    private static func isValidLocalPart(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 64,
              value.first != ".",
              value.last != ".",
              !value.contains("..")
        else {
            return false
        }
        return value.allSatisfy { character in
            character.isASCII && localPartCharacters.contains(character)
        }
    }

    private static let localPartCharacters = Set(
        "abcdefghijklmnopqrstuvwxyz0123456789.!#$%&'*+/=?^_`{|}~-"
    )

    private static let publicEmailDomains = Set([
        "126.com",
        "163.com",
        "aol.com",
        "fastmail.com",
        "fastmail.fm",
        "gmail.com",
        "gmx.com",
        "gmx.de",
        "googlemail.com",
        "hey.com",
        "hotmail.co.jp",
        "hotmail.com",
        "icloud.com",
        "live.com",
        "mac.com",
        "mail.com",
        "mail.ru",
        "me.com",
        "msn.com",
        "outlook.jp",
        "outlook.com",
        "proton.me",
        "protonmail.com",
        "qq.com",
        "yahoo.co.uk",
        "yahoo.com.au",
        "yahoo.co.jp",
        "yahoo.com",
        "yahoo.de",
        "yahoo.fr",
        "yandex.com",
        "yandex.ru",
        "zoho.com",
    ])
}

private extension Unicode.Scalar {
    var isPrintableASCII: Bool {
        (0x21 ... 0x7E).contains(value)
    }
}

private extension Character {
    var isASCIIDomainCharacter: Bool {
        isASCII && (isLetter || isNumber || self == "-")
    }
}
