import SwiftUI

private struct ScreenshotOverlayPresentationModifier: ViewModifier {
    @Binding var presentation: ExpandedScreenshotPresentation?
    let screenshots: () -> [MeetingScreenshotRecord]
    let summaryScreenshotIDs: () -> [UUID]
    let onDownload: (MeetingScreenshotRecord) -> Void
    let ocrStateProvider: @Sendable (UUID) async -> ScreenshotOCRState

    func body(content: Content) -> some View {
        content.overlay {
            if let presentation {
                ScreenshotOverlayView(
                    screenshot: presentation.screenshot,
                    previewImage: presentation.previewImage,
                    requestedAt: presentation.requestedAt,
                    canGoPrevious: neighbor(by: -1) != nil,
                    canGoNext: neighbor(by: 1) != nil,
                    onPrevious: { step(by: -1) },
                    onNext: { step(by: 1) },
                    onDownload: { onDownload(presentation.screenshot) },
                    onDismiss: dismiss,
                    ocrStateProvider: ocrStateProvider
                )
                .transition(.opacity)
            }
        }
    }

    private func navigationIDs(
        for scope: ExpandedScreenshotPresentation.Scope,
        in records: [MeetingScreenshotRecord]
    ) -> [UUID] {
        switch scope {
        case .allScreenshots:
            return records.map(\.id)
        case .summary:
            let availableIDs = Set(records.map(\.id))
            return summaryScreenshotIDs().filter(availableIDs.contains)
        }
    }

    private func neighbor(by offset: Int) -> MeetingScreenshotRecord? {
        let records = screenshots()
        guard let presentation,
              let neighborID = ScreenshotOverlayNavigation.neighborID(
                  in: navigationIDs(for: presentation.scope, in: records),
                  from: presentation.screenshot.id,
                  offset: offset
              ) else { return nil }
        return records.first { $0.id == neighborID }
    }

    private func step(by offset: Int) {
        guard let presentation,
              let neighbor = neighbor(by: offset) else { return }
        self.presentation = ExpandedScreenshotPresentation(
            screenshot: neighbor,
            previewImage: nil,
            requestedAt: .now,
            scope: presentation.scope
        )
    }

    private func dismiss() {
        guard presentation != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            presentation = nil
        }
    }
}

extension View {
    func screenshotOverlayPresentation(
        presentation: Binding<ExpandedScreenshotPresentation?>,
        screenshots: @escaping () -> [MeetingScreenshotRecord],
        summaryScreenshotIDs: @escaping () -> [UUID],
        onDownload: @escaping (MeetingScreenshotRecord) -> Void,
        ocrStateProvider: @escaping @Sendable (UUID) async -> ScreenshotOCRState
    ) -> some View {
        modifier(ScreenshotOverlayPresentationModifier(
            presentation: presentation,
            screenshots: screenshots,
            summaryScreenshotIDs: summaryScreenshotIDs,
            onDownload: onDownload,
            ocrStateProvider: ocrStateProvider
        ))
    }
}
