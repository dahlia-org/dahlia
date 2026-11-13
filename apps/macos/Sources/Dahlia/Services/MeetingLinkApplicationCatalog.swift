import AppKit
import Foundation

struct MeetingLinkApplicationCatalog: Sendable {
    static let empty = Self(globalApplications: [], applicationsByService: [:])

    let globalApplications: [MeetingLinkApplication]
    private let applicationsByService: [MeetingLinkService: [MeetingLinkApplication]]

    init(
        globalApplications: [MeetingLinkApplication],
        applicationsByService: [MeetingLinkService: [MeetingLinkApplication]]
    ) {
        let normalizedGlobalApplications = Self.uniqueSorted(globalApplications)
        self.globalApplications = normalizedGlobalApplications
        self.applicationsByService = Dictionary(uniqueKeysWithValues: MeetingLinkService.allCases.map { service in
            (
                service,
                Self.uniqueSorted(normalizedGlobalApplications + (applicationsByService[service] ?? []))
            )
        })
    }

    func applications(for service: MeetingLinkService) -> [MeetingLinkApplication] {
        applicationsByService[service] ?? globalApplications
    }

    private static func uniqueSorted(_ applications: [MeetingLinkApplication]) -> [MeetingLinkApplication] {
        var applicationsByBundleIdentifier: [String: MeetingLinkApplication] = [:]
        for application in applications {
            let bundleIdentifier = application.bundleIdentifier.lowercased()
            if applicationsByBundleIdentifier[bundleIdentifier] == nil {
                applicationsByBundleIdentifier[bundleIdentifier] = application
            }
        }
        return applicationsByBundleIdentifier.values.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            if comparison == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return comparison == .orderedAscending
        }
    }
}

extension MeetingLinkApplicationCatalog {
    static func load() async -> Self {
        await Task.detached(priority: .utility) {
            let globalApplications = webBrowsersThatCanOpen(
                URL(string: "https://example.com")!
            )
            let chromeApplications = chromeApplications()
            let applicationsByService = Dictionary(uniqueKeysWithValues: MeetingLinkService.allCases.map { service in
                (service, knownApplications(for: service) + (chromeApplications[service].map { [$0] } ?? []))
            })
            return Self(
                globalApplications: globalApplications,
                applicationsByService: applicationsByService
            )
        }.value
    }

    private static func webBrowsersThatCanOpen(_ url: URL) -> [MeetingLinkApplication] {
        NSWorkspace.shared.urlsForApplications(toOpen: url).compactMap { applicationURL in
            guard let infoDictionary = Bundle(url: applicationURL)?.infoDictionary,
                  isWebBrowser(infoDictionary: infoDictionary)
            else { return nil }
            return application(at: applicationURL)
        }
    }

    static func isWebBrowser(infoDictionary: [String: Any]) -> Bool {
        guard let urlTypes = infoDictionary["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        let schemes = Set(urlTypes.flatMap { urlType in
            urlType["CFBundleURLSchemes"] as? [String] ?? []
        }.map { $0.lowercased() })
        guard schemes.isSuperset(of: ["http", "https"]),
              let documentTypes = infoDictionary["CFBundleDocumentTypes"] as? [[String: Any]]
        else { return false }
        return documentTypes.contains { documentType in
            let contentTypes = documentType["LSItemContentTypes"] as? [String] ?? []
            let extensions = documentType["CFBundleTypeExtensions"] as? [String] ?? []
            return contentTypes.contains { ["public.html", "public.xhtml"].contains($0.lowercased()) }
                || extensions.contains { ["html", "htm", "xhtml", "xht"].contains($0.lowercased()) }
        }
    }

    private static func knownApplications(for service: MeetingLinkService) -> [MeetingLinkApplication] {
        let bundleIdentifiers: [String] = switch service {
        case .googleMeet:
            ["com.google.Chrome"]
        case .zoom:
            ["us.zoom.xos"]
        case .teams:
            ["com.microsoft.teams2", "com.microsoft.teams"]
        case .slack:
            ["com.tinyspeck.slackmacgap"]
        }

        return bundleIdentifiers.compactMap { bundleIdentifier in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
            return application(at: applicationURL)
        }
    }

    /// Chrome にインストールした、会議サービスの PWA。「Google Meet (PWA)」のように表示する。
    private static func chromeApplications() -> [MeetingLinkService: MeetingLinkApplication] {
        let chromeAppsDirectory = URL.homeDirectory
            .appending(path: "Applications")
            .appending(path: "Chrome Apps.localized")
        guard let applicationURLs = try? FileManager.default.contentsOfDirectory(
            at: chromeAppsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [:] }

        var applications: [MeetingLinkService: [(bundleIdentifier: String, host: String)]] = [:]
        for applicationURL in applicationURLs where applicationURL.pathExtension == "app" {
            guard let bundle = Bundle(url: applicationURL),
                  let bundleIdentifier = bundle.bundleIdentifier,
                  let infoDictionary = bundle.infoDictionary,
                  // インストール先のユーザーデータが消えた shim は開けない。
                  SystemMeetingLinkWorkspace.chromeAppInstallation(infoDictionary: infoDictionary) != nil,
                  let shortcutURL = chromeApplicationShortcutURL(infoDictionary: infoDictionary),
                  let service = MeetingLinkService(conferenceURL: shortcutURL),
                  // 会議リンクが PWA で開くことを確かめたサービスだけを出す。
                  [.googleMeet, .teams].contains(service),
                  let host = shortcutURL.host()
            else { continue }
            applications[service, default: []].append((bundleIdentifier, host))
        }
        return applications.reduce(into: [:]) { result, entry in
            // 一覧の順序は不定なので、選ぶ PWA が読み込みごとに変わらないよう並べ替える。
            let candidates = entry.value.sorted { ($0.bundleIdentifier, $0.host) < ($1.bundleIdentifier, $1.host) }
            guard let index = preferredChromeApplicationIndex(hosts: candidates.map(\.host)) else { return }
            result[entry.key] = MeetingLinkApplication(
                bundleIdentifier: candidates[index].bundleIdentifier,
                displayName: "\(entry.key.displayName) (PWA)"
            )
        }
    }

    static func chromeApplicationShortcutURL(infoDictionary: [String: Any]) -> URL? {
        (infoDictionary["CrAppModeShortcutURL"] as? String).flatMap(URL.init(string:))
    }

    /// サービスごとに PWA を 1 つだけ選ぶ。Teams は移行先の teams.cloud.microsoft を優先する。
    static func preferredChromeApplicationIndex(hosts: [String]) -> Int? {
        hosts.firstIndex(of: "teams.cloud.microsoft") ?? hosts.indices.first
    }

    private static func application(at url: URL) -> MeetingLinkApplication? {
        guard let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? FileManager.default.displayName(atPath: url.path)
        return MeetingLinkApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        )
    }
}
