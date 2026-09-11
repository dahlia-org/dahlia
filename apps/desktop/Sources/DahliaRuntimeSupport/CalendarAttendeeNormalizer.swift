import Foundation

public enum CalendarAttendeeNormalizer {
    public static func email(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 254,
              trimmed.unicodeScalars.allSatisfy(\.isPrintableASCII)
        else { return nil }

        let components = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let localPart = String(components[0]).lowercased()
        let domain = String(components[1]).lowercased()
        guard !localPart.isEmpty,
              localPart.utf8.count <= 64,
              localPart.first != ".",
              localPart.last != ".",
              !localPart.contains(".."),
              localPart.allSatisfy({ $0.isASCII && localPartCharacters.contains($0) }),
              isValidDomain(domain)
        else { return nil }
        return "\(localPart)@\(domain)"
    }

    public static func displayName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var utf16Count = 0
        return String(value.prefix {
            utf16Count += $0.utf16.count
            return utf16Count <= 500
        })
    }

    private static func isValidDomain(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static let localPartCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.!#$%&'*+/=?^_`{|}~-")
}

private extension Unicode.Scalar {
    var isPrintableASCII: Bool { (0x21 ... 0x7E).contains(value) }
}
