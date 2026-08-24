import SwiftUI

struct ScreenshotSearchHoverCard: View {
    static let descriptionLineLimit = 4

    let result: ScreenshotSearchResult
    let imageState: ScreenshotImageLoadModel.State

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScreenshotSearchResultImage(imageState: imageState)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: DahliaDesign.Media.cornerRadius))

            Text(result.meetingTitle)
                .bold()
                .lineLimit(2)

            Label(
                result.capturedAt.formatted(date: .abbreviated, time: .shortened),
                systemImage: "calendar"
            )

            Text(result.meetingDescription)
                .foregroundStyle(.black.opacity(0.7))
                .lineLimit(Self.descriptionLineLimit)

            ForEach(result.matches, id: \.source) { match in
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.source.localizedTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black.opacity(0.7))

                    Text(match.snippet)
                        .lineLimit(3)
                }
            }
        }
        .dahliaSidebarHoverCard(width: MainSearchDesign.screenshotHoverCardWidth)
        .accessibilityHidden(true)
    }
}
