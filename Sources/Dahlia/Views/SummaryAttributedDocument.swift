import AppKit
import DahliaRuntimeSupport

@MainActor
enum SummaryAttributedDocument {
    static func transcriptReferences(in summary: SummaryDocument) -> [TranscriptReference] {
        summary.sections.flatMap(\.blocks).flatMap { block in
            switch block.content {
            case let .paragraph(text), let .quote(text), let .code(_, text), let .heading(_, text):
                text.transcriptRef.map { [$0] } ?? []
            case let .bulletedList(items), let .numberedList(items):
                items.compactMap(\.transcriptRef)
            case let .checklist(items):
                items.compactMap(\.text.transcriptRef)
            case let .image(_, caption):
                caption.transcriptRef.map { [$0] } ?? []
            case let .table(headers, rows):
                (headers + rows.flatMap(\.self)).compactMap(\.transcriptRef)
            }
        }
    }

    static func render(
        _ summary: SummaryDocument,
        screenshotProvider: (UUID) -> MeetingScreenshotRecord?,
        onOpenImage: @escaping (UUID, CGImage) -> Void,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) -> NSAttributedString {
        let document = NSMutableAttributedString()

        if !summary.title.isEmpty {
            appendTextBlock(
                SummaryText(summary.title),
                font: boldFont(for: .title2),
                paragraphSpacing: DahliaDesign.blockSpacing + 2,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        }

        for section in summary.sections {
            if !section.heading.isEmpty {
                appendTextBlock(
                    SummaryText(section.heading),
                    font: boldFont(for: .title3),
                    paragraphSpacingBefore: DahliaDesign.sectionHeadingTopPadding,
                    to: document,
                    transcriptTextProvider: transcriptTextProvider,
                    allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
                )
            }

            for block in section.blocks {
                append(
                    block,
                    to: document,
                    screenshotProvider: screenshotProvider,
                    onOpenImage: onOpenImage,
                    transcriptTextProvider: transcriptTextProvider,
                    allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
                )
            }
        }

        appendActionItems(summary.actionItems, to: document)
        applyInlinePresentationStyles(to: document)
        return document
    }

    // The switch deliberately mirrors every persisted summary block type in display order.
    // swiftlint:disable:next function_body_length
    private static func append(
        _ block: SummaryBlock,
        to document: NSMutableAttributedString,
        screenshotProvider: (UUID) -> MeetingScreenshotRecord?,
        onOpenImage: @escaping (UUID, CGImage) -> Void,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) {
        switch block.content {
        case let .paragraph(text):
            appendTextBlock(
                text,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        case let .bulletedList(items):
            appendList(
                items,
                marker: { _ in "•" },
                markerColor: .secondaryLabelColor,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        case let .numberedList(items):
            appendList(
                items,
                marker: { "\($0 + 1)." },
                markerFont: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                    weight: .regular
                ),
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        case let .checklist(items):
            appendChecklist(
                items,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        case let .quote(text):
            appendQuote(
                text,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        case let .code(_, content):
            appendCode(
                content,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        case let .image(screenshotID, caption):
            appendImage(
                screenshotID: screenshotID,
                caption: caption,
                to: document,
                screenshotProvider: screenshotProvider,
                onOpenImage: onOpenImage,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        case let .heading(level, content):
            appendTextBlock(
                content,
                font: headingFont(level: level),
                paragraphSpacingBefore: level <= 2 ? DahliaDesign.sectionHeadingTopPadding : 2,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        case let .table(headers, rows):
            appendTable(
                headers: headers,
                rows: rows,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
            )
        }
    }
}
