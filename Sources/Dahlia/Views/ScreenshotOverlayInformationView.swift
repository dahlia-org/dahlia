import CoreGraphics
import SwiftUI

struct ScreenshotOverlayInformationView: View {
    let screenshot: MeetingScreenshotRecord
    let image: CGImage?
    let ocrState: ScreenshotOCRState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.imageInformation)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(L10n.capturedAt) {
                        Text(screenshot.capturedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    LabeledContent(L10n.fileType, value: screenshot.mimeType)
                    LabeledContent(
                        L10n.fileSize,
                        value: screenshot.imageData.count.formatted(.byteCount(style: .file))
                    )
                    if let image {
                        LabeledContent(L10n.imageDimensions, value: "\(image.width) × \(image.height)")
                    }
                }

                Divider()

                Text(L10n.imageDescription)
                    .font(.headline)
                captionContent

                Divider()

                Text(L10n.detectedText)
                    .font(.headline)
                ocrContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .dahliaCardSurface()
    }

    @ViewBuilder
    private var ocrContent: some View {
        switch ocrState {
        case let .completed(text, _):
            if text.isEmpty {
                Text(L10n.noTextDetected)
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed:
            Text(L10n.imageAnalysisFailed)
                .foregroundStyle(.secondary)
        case .pending, .processing:
            ProgressView(L10n.analyzingImage)
        }
    }

    @ViewBuilder
    private var captionContent: some View {
        switch ocrState {
        case let .completed(_, caption):
            Text(caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            Text(L10n.imageAnalysisFailed)
                .foregroundStyle(.secondary)
        case .pending, .processing:
            ProgressView(L10n.analyzingImage)
        }
    }
}
