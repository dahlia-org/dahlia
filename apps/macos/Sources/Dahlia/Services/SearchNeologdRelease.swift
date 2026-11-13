import Foundation

struct SearchNeologdRelease: Codable, Equatable, Identifiable, Sendable {
    let version: String
    let sha256: String
    let size: Int64

    var id: String { "neologd-\(version)-\(sha256)" }
    var downloadURL: URL {
        URL(string: "https://github.com/lindera/lindera/releases/download/v\(version)/lindera-ipadic-neologd-\(version).zip")!
    }

    var isValid: Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { "0123456789".contains($0) } && Int($0) != nil }
            && sha256.count == 64 && sha256.allSatisfy { "0123456789abcdef".contains($0) } && size >= 0
    }

    init(version: String, sha256: String, size: Int64 = 0) {
        self.version = version
        self.sha256 = sha256
        self.size = size
    }

    init?(directoryName: String) {
        let parts = directoryName.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "neologd" else { return nil }
        self.init(version: String(parts[1]), sha256: String(parts[2]))
        guard isValid else { return nil }
    }

    static func newerFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.version == rhs.version { return lhs.id < rhs.id }
        return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
    }
}
