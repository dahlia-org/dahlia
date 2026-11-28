import Foundation

/// Skills shared by the app's Pi presets and the `dahlia-mcp` helper, which both read the runtime support bundle.
public enum DahliaBundledSkills {
    public static var rootURL: URL? {
        Bundle.runtimeSupport.url(forResource: "Skills", withExtension: nil)
    }

    /// Every skill directory in the bundle, sorted.
    public static let names: [String] = rootURL
        .flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?
        .filter { !$0.hasPrefix(".") }
        .sorted() ?? []

    public static func url(named name: String) -> URL? {
        guard let url = rootURL?.appending(path: name, directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
