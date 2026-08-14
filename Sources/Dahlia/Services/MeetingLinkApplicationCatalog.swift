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
            let applicationsByService = Dictionary(uniqueKeysWithValues: MeetingLinkService.allCases.map { service in
                var applications = knownApplications(for: service)
                if service == .googleMeet {
                    applications.append(contentsOf: googleMeetChromeApplications())
                }
                return (service, applications)
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

    private static func googleMeetChromeApplications() -> [MeetingLinkApplication] {
        let chromeAppsDirectory = URL.homeDirectory
            .appending(path: "Applications")
            .appending(path: "Chrome Apps.localized")
        guard let applicationURLs = try? FileManager.default.contentsOfDirectory(
            at: chromeAppsDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return applicationURLs.compactMap { applicationURL in
            guard applicationURL.pathExtension == "app",
                  let bundle = Bundle(url: applicationURL),
                  let infoDictionary = bundle.infoDictionary,
                  isGoogleMeetChromeApplication(infoDictionary: infoDictionary)
            else { return nil }
            return application(at: applicationURL)
        }
    }

    static func isGoogleMeetChromeApplication(infoDictionary: [String: Any]) -> Bool {
        guard let shortcutURLString = infoDictionary["CrAppModeShortcutURL"] as? String,
              let shortcutURL = URL(string: shortcutURLString)
        else { return false }
        return MeetingLinkService(conferenceURL: shortcutURL) == .googleMeet
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
