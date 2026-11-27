import Foundation

/// What a Source sends: the intake request for an MCP Source, which the editor's preview shows, and the calendar's
/// signal notes.
enum AgentSourcePrompt {
    /// The intake request, run through the bundled intake skill. Pi takes the text after the first space as the request.
    static func intake(_ source: AgentSourceRecord, since: String) -> String {
        let options = source.sourceOptions
        let notes = source.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["Source: \(source.name)"]
        switch source.service {
        case "mail":
            if options.addressedOnly == true {
                lines.append(
                    "Read only mail that has the user's own address in To or Cc. Skip mail that reached the user through a "
                        + "mailing list or a group address. Narrow the search when the tools allow it, for Gmail with {to:me cc:me}."
                )
            }
            let senders = (try? JSONDecoder().decode([String].self, from: Data(source.allowedSenders.utf8))) ?? []
            let domains = options.allowedDomains ?? []
            if !senders.isEmpty || !domains.isEmpty {
                lines.append(
                    "Read only mail from these senders or from these domains and their subdomains: "
                        + (senders + domains).joined(separator: ", ") + ". Narrow the search with them when the tools allow it."
                )
            }
        case "slack":
            switch options.slackScope {
            case .mentions: lines.append("Read only messages that mention the user and direct messages to the user, including group DMs.")
            case .joined:
                lines.append("Read messages that mention the user, direct messages to the user, and messages in channels the user has joined.")
            case .all:
                lines.append(
                    "Read messages that mention the user, direct messages to the user, and messages in channels the user can read, "
                        + "including channels the user has not joined."
                )
            case nil: break
            }
            if let channels = options.includeChannels, !channels.isEmpty {
                lines.append(
                    "Read channel messages only in these channels: \(list(channels)). Mentions and direct messages follow the scope above."
                )
            }
            if let channels = options.excludeChannels, !channels.isEmpty {
                lines.append("Never read these channels, even when the user is mentioned there: \(list(channels)).")
            }
        default:
            lines.append("What to read: \(notes)")
        }
        if source.service == "mail" || source.service == "slack", !notes.isEmpty {
            lines.append("The user's notes on what to read: \(notes)")
        }
        lines.append("Read the items that arrived since \(since).")
        return "/skill:intake " + lines.joined(separator: "\n")
    }

    static func dailyNote(_ source: AgentSourceRecord) -> String {
        L10n.agentCalendarDailyNote + acceptedOnly(source)
    }

    static func weeklyNote(_ source: AgentSourceRecord) -> String {
        L10n.agentCalendarWeeklyNote + acceptedOnly(source)
    }

    private static func acceptedOnly(_ source: AgentSourceRecord) -> String {
        source.sourceOptions.acceptedOnly == true ? L10n.agentCalendarAcceptedOnlyNote : ""
    }

    private static func list(_ channels: [String]) -> String {
        channels.map { "#" + $0 }.joined(separator: ", ")
    }
}
