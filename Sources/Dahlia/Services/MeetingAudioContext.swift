enum MeetingAudioContext: Hashable, Sendable {
    case zoom
    case teams
    case slack
    case discord
    case webex
    case faceTime
    case chrome
    case edge
    case brave
    case arc
    case firefox
    case chromium
    case vivaldi
    case opera
    case atlas
    case comet

    var isBrowser: Bool {
        switch self {
        case .zoom, .teams, .slack, .discord, .webex, .faceTime:
            false
        case .chrome, .edge, .brave, .arc, .firefox, .chromium, .vivaldi, .opera, .atlas, .comet:
            true
        }
    }
}

enum MeetingAudioWindowCatalog {
    private static let browserContextsByApplicationName: [String: MeetingAudioContext] = [
        "Google Chrome": .chrome,
        "Microsoft Edge": .edge,
        "Arc": .arc,
        "Firefox": .firefox,
        "Brave Browser": .brave,
        "Chromium": .chromium,
        "Vivaldi": .vivaldi,
        "Opera": .opera,
        "Atlas": .atlas,
        "Comet": .comet,
    ]

    static func browserContext(forApplicationName applicationName: String) -> MeetingAudioContext? {
        browserContextsByApplicationName[applicationName]
    }
}

enum MeetingAudioProcessCatalog {
    struct Entry: Sendable {
        let prefix: String
        let context: MeetingAudioContext
    }

    static let bundleIDPrefixes: [Entry] = [
        Entry(prefix: "us.zoom.xos", context: .zoom),
        Entry(prefix: "us.zoom.caphost", context: .zoom),
        Entry(prefix: "com.microsoft.teams2", context: .teams),
        Entry(prefix: "com.microsoft.teams", context: .teams),
        Entry(prefix: "com.tinyspeck.slackmacgap", context: .slack),
        Entry(prefix: "com.hnc.discord", context: .discord),
        Entry(prefix: "cisco-systems.spark", context: .webex),
        Entry(prefix: "com.cisco.webexmeetingsapp", context: .webex),
        Entry(prefix: "com.apple.facetime", context: .faceTime),
        Entry(prefix: "com.google.chrome.helper", context: .chrome),
        Entry(prefix: "com.microsoft.edgemac.helper", context: .edge),
        Entry(prefix: "com.brave.browser.helper", context: .brave),
        Entry(prefix: "company.thebrowser.browser.helper", context: .arc),
        Entry(prefix: "org.mozilla.firefox", context: .firefox),
        Entry(prefix: "org.chromium.chromium.helper", context: .chromium),
        Entry(prefix: "com.vivaldi.vivaldi.helper", context: .vivaldi),
        Entry(prefix: "com.operasoftware.opera.helper", context: .opera),
        Entry(prefix: "com.openai.atlas.web.helper", context: .atlas),
        Entry(prefix: "ai.perplexity.comet.helper", context: .comet),
    ]

    static func contexts(for bundleIDs: Set<String>) -> Set<MeetingAudioContext> {
        Set(bundleIDs.compactMap(context(for:)))
    }

    static func context(for bundleID: String) -> MeetingAudioContext? {
        let normalizedBundleID = bundleID.lowercased()
        return bundleIDPrefixes.first { entry in
            normalizedBundleID == entry.prefix || normalizedBundleID.hasPrefix("\(entry.prefix).")
        }?.context
    }
}
