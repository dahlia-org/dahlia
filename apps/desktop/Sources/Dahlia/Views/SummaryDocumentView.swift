import AppKit
import DahliaRuntimeSupport
import SwiftUI

struct SummaryDocumentView: View {
    let document: SummaryDocument
    let screenshotProvider: (UUID) -> MeetingScreenshotRecord?
    let onOpenImage: (UUID, CGImage) -> Void
    let transcriptTextProvider: (TranscriptReference) -> String?

    init(
        document: SummaryDocument,
        screenshotProvider: @escaping (UUID) -> MeetingScreenshotRecord?,
        onOpenImage: @escaping (UUID, CGImage) -> Void,
        transcriptTextProvider: @escaping (TranscriptReference) -> String? = { _ in nil }
    ) {
        self.document = document
        self.screenshotProvider = screenshotProvider
        self.onOpenImage = onOpenImage
        self.transcriptTextProvider = transcriptTextProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DahliaDesign.blockSpacing) {
            ForEach(document.sections) { section in
                sectionView(section)
            }

            SummaryActionItemsView(actionItems: document.actionItems)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func sectionView(_ section: SummarySection) -> some View {
        if !section.heading.isEmpty {
            inlineMarkdownText(section.heading)
                .font(.title2)
                .bold()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DahliaDesign.sectionHeadingTopPadding)
        }

        ForEach(section.blocks) { block in
            blockView(block)
        }
    }

    private func blockView(_ block: SummaryBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch block.content {
            case let .paragraph(text):
                summaryTextView(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.body)
                    .lineSpacing(DahliaDesign.paragraphLineSpacing)
            case let .bulletedList(items):
                VStack(alignment: .leading, spacing: DahliaDesign.listItemSpacing) {
                    ForEach(items.enumerated(), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                                .foregroundStyle(DahliaDesign.secondaryTextColor)
                            summaryTextView(item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(DahliaDesign.paragraphLineSpacing)
                        }
                        .font(.body)
                    }
                }
                .padding(.leading, 8)
            case let .numberedList(items):
                VStack(alignment: .leading, spacing: DahliaDesign.listItemSpacing) {
                    ForEach(items.enumerated(), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                                .monospacedDigit()
                            summaryTextView(item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(DahliaDesign.paragraphLineSpacing)
                        }
                        .font(.body)
                    }
                }
                .padding(.leading, 8)
            case let .checklist(items):
                VStack(alignment: .leading, spacing: DahliaDesign.listItemSpacing) {
                    ForEach(items.enumerated(), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.checked ? "checkmark.square" : "square")
                                .dahliaFixedSymbol()
                                .foregroundStyle(item.checked ? DahliaDesign.secondaryTextColor : DahliaDesign.optionalTextColor)
                            summaryTextView(item.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(DahliaDesign.paragraphLineSpacing)
                        }
                        .font(.body)
                    }
                }
                .padding(.leading, 8)
            case let .quote(text):
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 3)
                    summaryTextView(text)
                        .font(.body)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(DahliaDesign.paragraphLineSpacing)
                        .padding(.leading, 8)
                }
                .padding(.vertical, 2)
            case let .code(_, content):
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.text)
                        .font(.body.monospaced())
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    transcriptReferenceView(content.transcriptRef)
                }
            case let .image(screenshotId, caption):
                imageView(screenshotId: screenshotId, caption: caption)
            case let .heading(level, content):
                headingView(level: level, content: content)
            case let .table(headers, rows):
                tableView(headers: headers, rows: rows)
            }
        }
    }

    @ViewBuilder
    private func headingView(level: Int, content: SummaryText) -> some View {
        switch level {
        case 1:
            summaryTextView(content)
                .font(.title2)
                .bold()
                .padding(.top, DahliaDesign.sectionHeadingTopPadding)
        case 2:
            summaryTextView(content)
                .font(.title3)
                .padding(.top, DahliaDesign.sectionHeadingTopPadding)
        default:
            summaryTextView(content)
                .font(.title3)
                .padding(.top, 2)
        }
    }

    private func imageView(screenshotId: UUID, caption: SummaryText) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let screenshot = screenshotProvider(screenshotId) {
                SummaryScreenshotImageView(
                    screenshot: screenshot,
                    accessibilityLabel: L10n.enlargeScreenshot(caption: caption.text.nilIfBlank),
                    onOpen: onOpenImage
                )
            } else {
                Text(L10n.summaryImageUnavailable)
                    .font(.body)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }

            if !caption.text.isEmpty {
                summaryTextView(caption)
                    .font(.footnote)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                transcriptReferenceView(caption.transcriptRef)
            }
        }
    }

    private func tableView(headers: [SummaryText], rows: [[SummaryText]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(headers.enumerated(), id: \.offset) { _, header in
                    tableCellView(header)
                        .font(.body.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06))
                }
            }
            Divider()
            ForEach(rows.enumerated(), id: \.offset) { _, row in
                GridRow {
                    ForEach(row.enumerated(), id: \.offset) { _, cell in
                        tableCellView(cell)
                            .font(.body)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
            }
        }
        .border(Color.primary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func summaryTextView(_ summaryText: SummaryText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !summaryText.text.isEmpty {
                inlineMarkdownText(summaryText.text)
            }
            transcriptReferenceView(summaryText.transcriptRef)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableCellView(_ summaryText: SummaryText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !summaryText.text.isEmpty {
                inlineMarkdownText(summaryText.text)
            }
            transcriptReferenceView(summaryText.transcriptRef)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func transcriptReferenceView(_ ref: TranscriptReference?) -> some View {
        if let ref {
            TranscriptReferenceChip(
                reference: ref,
                transcriptText: transcriptTextProvider(ref)
            )
        }
    }

    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }

}

struct SummaryScreenshotImageView: View {
    let screenshot: MeetingScreenshotRecord
    let accessibilityLabel: String
    let onOpen: (UUID, CGImage) -> Void
    @State private var imageLoader = ScreenshotImageLoadModel()

    var body: some View {
        Group {
            if case let .loaded(image) = imageLoader.state {
                ZStack(alignment: .topTrailing) {
                    Button {
                        activate(image)
                    } label: {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityLabel(accessibilityLabel)
                    .help(accessibilityLabel)

                    Button(L10n.copyImage, systemImage: "doc.on.doc", action: copyImageToGeneralPasteboard)
                        .labelStyle(.iconOnly)
                        .dahliaFixedSymbol()
                        .buttonStyle(.plain)
                        .padding(6)
                        .background(.regularMaterial, in: .circle)
                        .padding(8)
                        .help(L10n.copyImage)
                }
                .contextMenu {
                    Button(L10n.copyImage, systemImage: "doc.on.doc", action: copyImageToGeneralPasteboard)
                }
            } else if case .failed = imageLoader.state {
                Text(L10n.summaryImageUnavailable)
                    .font(.body)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: screenshot.id) {
            await imageLoader.load(
                screenshotID: screenshot.id,
                data: screenshot.imageData,
                maxPixelSize: 1200
            )
        }
    }

    func activate(_ image: CGImage) {
        onOpen(screenshot.id, image)
    }

    private func copyImageToGeneralPasteboard() {
        Task {
            await copyImage(to: .general)
        }
    }

    func copyImage(to pasteboard: NSPasteboard = .general) async {
        await ScreenshotPasteboardWriter.write(screenshot, to: pasteboard)
    }
}

private struct TranscriptReferenceChip: View {
    let reference: TranscriptReference
    let transcriptText: String?

    @State private var isTranscriptPopoverPresented = false

    var body: some View {
        Text(reference.time)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(DahliaDesign.secondaryTextColor)
            .padding(.horizontal, DahliaDesign.timestampChipHorizontalPadding)
            .padding(.vertical, DahliaDesign.timestampChipVerticalPadding)
            .background(Color.primary.opacity(DahliaDesign.timestampChipBackgroundOpacity), in: Capsule())
            .onHover { isHovering in
                isTranscriptPopoverPresented = isHovering
                    && transcriptText?.nilIfBlank != nil
            }
            .popover(isPresented: $isTranscriptPopoverPresented, arrowEdge: .bottom) {
                if let transcriptText = transcriptText?.nilIfBlank {
                    Text(transcriptText)
                        .font(.body)
                        .foregroundStyle(DahliaDesign.primaryTextColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding(10)
                }
            }
    }
}
