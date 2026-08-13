import AppKit
import DahliaRuntimeSupport
import SwiftUI

extension SummaryAttributedDocument {
    // Image blocks need both attachment presentation and adjacent transcript-reference configuration.
    // swiftlint:disable:next function_parameter_count
    static func appendImage(
        screenshotID: UUID,
        caption: SummaryText,
        to document: NSMutableAttributedString,
        screenshotProvider: (UUID) -> MeetingScreenshotRecord?,
        onOpenImage: @escaping (UUID, CGImage) -> Void,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) {
        beginBlock(in: document)
        let screenshot = screenshotProvider(screenshotID)
        let attachment = screenshotAttachment(
            screenshot,
            caption: caption.text,
            onOpenImage: onOpenImage
        )
        let location = document.length
        appendAttachment(attachment, to: document)
        let hasCaption = !caption.text.isEmpty || caption.transcriptRef != nil
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = hasCaption ? 6 : DahliaDesign.blockSpacing
        document.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: location, length: 1)
        )

        guard hasCaption else { return }
        appendTextBlock(
            caption,
            font: NSFont.preferredFont(forTextStyle: .caption1),
            color: .secondaryLabelColor,
            to: document,
            transcriptTextProvider: transcriptTextProvider,
            allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
        )
    }

    static func appendTranscriptReference(
        _ reference: TranscriptReference?,
        to document: NSMutableAttributedString,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsPopover: Bool
    ) {
        guard let reference else { return }
        if document.length > 0, document.mutableString.character(at: document.length - 1) != 0x0A {
            document.append(NSAttributedString(
                string: " ",
                attributes: [SummarySelectableNSTextView.copyReplacementAttribute: ""]
            ))
        }

        let font = NSFont.preferredFont(forTextStyle: .caption2)
        let textSize = (reference.time as NSString).size(withAttributes: [.font: font])
        let size = CGSize(
            width: ceil(textSize.width + 2 * DahliaDesign.timestampChipHorizontalPadding),
            height: ceil(font.ascender - font.descender + 2 * DahliaDesign.timestampChipVerticalPadding)
        )
        let transcriptText = transcriptTextProvider(reference)
        let attachment = SummaryViewAttachment(
            sizeProvider: { _ in size },
            baselineOffset: -3,
            hostedViewProvider: { _ in
                NSHostingView(rootView: SummaryTranscriptReferenceChip(
                    reference: reference,
                    transcriptText: transcriptText,
                    allowsPopover: allowsPopover
                ).fixedSize())
            }
        )
        appendAttachment(attachment, to: document)
    }

    static func screenshotAttachment(
        _ screenshot: MeetingScreenshotRecord?,
        caption: String,
        onOpenImage: @escaping (UUID, CGImage) -> Void
    ) -> SummaryViewAttachment {
        SummaryViewAttachment(
            sizeProvider: { availableWidth in
                let width = max(1, availableWidth)
                return CGSize(width: width, height: screenshot == nil ? 40 : 120)
            },
            usesImageSizing: screenshot != nil,
            hostedViewProvider: { attachment in
                if let screenshot {
                    return NSHostingView(rootView: SummaryScreenshotImageView(
                        screenshot: screenshot,
                        accessibilityLabel: L10n.enlargeScreenshot(caption: caption.nilIfBlank),
                        onOpen: onOpenImage,
                        onImageLoaded: attachment.updateImageSize
                    ))
                }

                return NSHostingView(rootView: Text(L10n.summaryImageUnavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6)))
            }
        )
    }

    static func appendAttachment(
        _ attachment: NSTextAttachment,
        to document: NSMutableAttributedString
    ) {
        let attributedAttachment = NSMutableAttributedString(attachment: attachment)
        attributedAttachment.addAttribute(
            SummarySelectableNSTextView.copyReplacementAttribute,
            value: "",
            range: NSRange(location: 0, length: attributedAttachment.length)
        )
        document.append(attributedAttachment)
    }
}
