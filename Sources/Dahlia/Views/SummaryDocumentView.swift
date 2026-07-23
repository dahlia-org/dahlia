import SwiftUI

struct SummaryDocumentView: View {
    let document: SummaryDocument
    let imageDataProvider: (UUID) -> Data?
    let transcriptTextProvider: (TranscriptReference) -> String?
    let allowsTranscriptReferencePopovers: Bool

    init(
        document: SummaryDocument,
        imageDataProvider: @escaping (UUID) -> Data?,
        transcriptTextProvider: @escaping (TranscriptReference) -> String? = { _ in nil },
        allowsTranscriptReferencePopovers: Bool = true
    ) {
        self.document = document
        self.imageDataProvider = imageDataProvider
        self.transcriptTextProvider = transcriptTextProvider
        self.allowsTranscriptReferencePopovers = allowsTranscriptReferencePopovers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !document.title.isEmpty {
                inlineMarkdownText(document.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }

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
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
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
            case let .bulletedList(items):
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            summaryTextView(item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.body)
                    }
                }
                .padding(.leading, 8)
            case let .numberedList(items):
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                                .monospacedDigit()
                            summaryTextView(item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.body)
                    }
                }
                .padding(.leading, 8)
            case let .checklist(items):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: item.checked ? "checkmark.square" : "square")
                                .foregroundStyle(item.checked ? .secondary : .tertiary)
                            summaryTextView(item.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
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
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 8)
                }
                .padding(.vertical, 2)
            case let .code(_, content):
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.text)
                        .font(.system(.callout, design: .monospaced))
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
        case 1, 2:
            summaryTextView(content)
                .font(.title3.bold())
                .padding(.top, 4)
        case 3:
            summaryTextView(content)
                .font(.headline)
                .padding(.top, 2)
        default:
            summaryTextView(content)
                .font(.subheadline.bold())
                .padding(.top, 2)
        }
    }

    private func imageView(screenshotId: UUID, caption: SummaryText) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let data = imageDataProvider(screenshotId) {
                SummaryScreenshotImageView(screenshotID: screenshotId, data: data)
            } else {
                Text(L10n.summaryImageUnavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }

            if !caption.text.isEmpty {
                summaryTextView(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    tableCellView(header)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06))
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        tableCellView(cell)
                            .font(.caption)
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
                transcriptText: transcriptTextProvider(ref),
                allowsPopover: allowsTranscriptReferencePopovers
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

private struct SummaryScreenshotImageView: View {
    let screenshotID: UUID
    let data: Data
    @StateObject private var imageLoader = ScreenshotImageLoadModel()

    var body: some View {
        Group {
            if case let .loaded(image) = imageLoader.state {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if case .failed = imageLoader.state {
                Text(L10n.summaryImageUnavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: screenshotID) {
            await imageLoader.load(
                screenshotID: screenshotID,
                data: data,
                maxPixelSize: 1200
            )
        }
    }
}

private struct TranscriptReferenceChip: View {
    let reference: TranscriptReference
    let transcriptText: String?
    let allowsPopover: Bool

    @State private var isTranscriptPopoverPresented = false

    var body: some View {
        Text(reference.time)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .onHover { isHovering in
                isTranscriptPopoverPresented = allowsPopover
                    && isHovering
                    && transcriptText?.nilIfBlank != nil
            }
            .onChange(of: allowsPopover) {
                guard !allowsPopover else { return }
                isTranscriptPopoverPresented = false
            }
            .popover(isPresented: $isTranscriptPopoverPresented, arrowEdge: .bottom) {
                if let transcriptText = transcriptText?.nilIfBlank {
                    Text(transcriptText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding(10)
                }
            }
    }
}
