import CryptoKit
import DahliaRuntimeSupport
import Foundation

/// A bundled skill directory served through the MCP Skills extension (SEP-2640), one resource per file.
struct DahliaMCPSkill {
    static let extensionID = "io.modelcontextprotocol/skills"
    /// Skills whose workflow ends in a write tool; read-only servers do not offer them.
    private static let writeOnlyNames: Set = ["summary-editor"]

    struct File {
        let uri: String
        let path: String
        let data: Data

        var mimeType: String {
            switch (path as NSString).pathExtension {
            case "md": "text/markdown"
            case "yaml", "yml": "application/yaml"
            default: "text/plain"
            }
        }
    }

    let name: String
    let frontmatter: [String: String]
    let files: [File]

    var requiresWrites: Bool { Self.writeOnlyNames.contains(name) }
    var uri: String { Self.uri(name, "SKILL.md") }

    var entry: [String: Any] {
        [
            "uri": uri,
            "frontmatter": frontmatter,
            "resources": files.map { file in
                let digest = SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
                return ["uri": file.uri, "digest": "sha256:\(digest)", "size": file.data.count] as [String: Any]
            },
        ]
    }

    var resources: [[String: Any]] {
        files.map { file in
            file.path == "SKILL.md"
                ? ["uri": file.uri, "name": name, "description": frontmatter["description"] ?? "", "mimeType": file.mimeType]
                : ["uri": file.uri, "name": "\(name)/\(file.path)", "mimeType": file.mimeType]
        }
    }

    static let all: [Self] = {
        guard let root = DahliaBundledSkills.rootURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { load(name: $0, directory: root.appending(path: $0)) }
    }()

    private static func uri(_ name: String, _ path: String) -> String { "skill://dahlia/\(name)/\(path)" }

    private static func load(name: String, directory: URL) -> Self? {
        guard let paths = FileManager.default.subpaths(atPath: directory.path) else { return nil }
        let files = paths.sorted().compactMap { path -> File? in
            var isDirectory: ObjCBool = false
            let url = directory.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let data = try? Data(contentsOf: url) else { return nil }
            return File(uri: uri(name, path), path: path, data: data)
        }
        guard let skillFile = files.first(where: { $0.path == "SKILL.md" }) else { return nil }
        let frontmatter = parseFrontmatter(String(decoding: skillFile.data, as: UTF8.self))
        guard frontmatter["name"] == name, frontmatter["description"] != nil else { return nil }
        return Self(name: name, frontmatter: frontmatter, files: files)
    }

    /// shortcut: reads only flat `key: value` lines, which is all the bundled skills use; nested YAML needs a parser.
    static func parseFrontmatter(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var result: [String: String] = [:]
        for line in lines[1 ..< end] {
            guard let separator = line.range(of: ": ") else { continue }
            result[String(line[..<separator.lowerBound])] = String(line[separator.upperBound...])
        }
        return result
    }
}

extension DahliaMCPServer {
    var skills: [DahliaMCPSkill] {
        DahliaMCPSkill.all.filter { store.allowsWrites || !$0.requiresWrites }
    }

    func skill(_ params: Any?) -> DahliaMCPSkill? {
        let uri = (params as? [String: Any])?["uri"] as? String
        return skills.first { $0.uri == uri }
    }

    func skillFile(_ params: Any?) -> DahliaMCPSkill.File? {
        let uri = (params as? [String: Any])?["uri"] as? String
        return skills.lazy.flatMap(\.files).first { $0.uri == uri }
    }
}
