import AppKit
import SwiftUI

struct ScreenshotSearchResultTile: View {
    let result: ScreenshotSearchResult
    let isSelected: Bool
    let imageDataProvider: (UUID) async -> Data?
    let action: () -> Void

    @State private var imageLoader = ScreenshotImageLoadModel()
    @State private var hoverController = DahliaWindowHeaderHelpController()
    @State private var isHovered = false

    var body: some View {
        let isHoverCardPresented = hoverController.visibleHelpID == result.id

        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ScreenshotSearchResultImage(imageState: imageLoader.state)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: DahliaDesign.Media.cornerRadius))

                Text(result.capturedAt.formatted(date: .numeric, time: .shortened))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .lineLimit(1)
            }
            .padding(5)
            .contentShape(.rect)
            .background(
                isSelected || isHovered ? DahliaDesign.contentHighlightColor : .clear,
                in: .rect(cornerRadius: MainSearchDesign.rowCornerRadius)
            )
        }
        .buttonStyle(.plain)
        .onHover(perform: updateHover)
        .popover(
            isPresented: Binding(
                get: { isHoverCardPresented },
                set: { isPresented in
                    if !isPresented {
                        let shouldOpen = Self.shouldOpenAfterPopoverDismissal(
                            isHovered: isHovered,
                            pressedMouseButtons: NSEvent.pressedMouseButtons
                        )
                        hoverController.dismissAll()
                        if shouldOpen {
                            action()
                        }
                    }
                }
            ),
            arrowEdge: .top
        ) {
            ScreenshotSearchHoverCard(result: result, imageState: imageLoader.state)
        }
        .accessibilityLabel(accessibilityLabel)
        .task(id: result.id) {
            guard let data = await imageDataProvider(result.id), !Task.isCancelled else { return }
            await imageLoader.load(
                screenshotID: result.id,
                data: data,
                maxPixelSize: MainSearchDesign.screenshotImageMaxPixelSize
            )
        }
        .onDisappear {
            hoverController.dismissAll()
            imageLoader.unload()
        }
    }

    private func updateHover(_ isHovering: Bool) {
        isHovered = isHovering
        if isHovering {
            hoverController.hoverBegan(for: result.id)
        } else {
            hoverController.hoverEnded(for: result.id)
        }
    }

    static func shouldOpenAfterPopoverDismissal(isHovered: Bool, pressedMouseButtons: Int) -> Bool {
        isHovered && pressedMouseButtons & 1 == 1
    }

    private var accessibilityLabel: String {
        let matches = result.matches.map {
            "\($0.source.localizedTitle): \($0.snippet)"
        }.joined(separator: ", ")
        return "\(result.meetingTitle), \(result.capturedAt.formatted(date: .numeric, time: .shortened)), \(matches)"
    }
}
