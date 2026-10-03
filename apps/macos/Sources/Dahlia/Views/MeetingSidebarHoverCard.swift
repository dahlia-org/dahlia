import SwiftUI

struct MeetingSidebarHoverCard: View {
    static let descriptionLineLimit = 3

    let item: MeetingSidebarItem
    let description: String
    let isActiveRecording: Bool
    let projectAppearance: ProjectAppearance?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(item.displayTitle)
                    .bold()
                    .lineLimit(2)

                Spacer(minLength: 0)

                Text(durationText)
                    .foregroundStyle(.black.opacity(0.55))
                    .fixedSize()
            }

            if let projectName {
                HStack(spacing: 6) {
                    ProjectAppearanceIcon(appearance: projectAppearance ?? .default)

                    Text(projectName)
                }
                .lineLimit(1)
            }

            Label(
                item.effectiveRecordingStartedAt.formatted(date: .abbreviated, time: .shortened),
                systemImage: "calendar"
            )

            Text(description.nilIfBlank ?? "—")
                .foregroundStyle(.black.opacity(0.7))
                .lineLimit(Self.descriptionLineLimit)
        }
        .dahliaSidebarHoverCard()
        .accessibilityHidden(true)
    }

    var durationText: String {
        if isActiveRecording {
            return L10n.recordingNow
        }
        guard let duration = item.duration else { return "—" }
        let wholeMinutes = Int(max(0, duration)) / 60
        return Duration.seconds(wholeMinutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .narrow)
        )
    }

    var projectName: String? {
        item.projectName?.nilIfBlank
    }
}
