import AppKit

enum ObsidianLauncher {
    private static let bundleIdentifier = "md.obsidian"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static func open(_ url: URL) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]

        guard let obsidianURL = components.url else { return }
        NSWorkspace.shared.open(obsidianURL)
    }
}
