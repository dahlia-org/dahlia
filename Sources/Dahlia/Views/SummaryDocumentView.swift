import AppKit
import SwiftUI

struct SummaryDocumentView: View {
    let document: SummaryDocument
    let imageProvider: (UUID) -> NSImage?
    @State private var imageCache: [UUID: NSImage] = [:]
    @State private var attemptedImageLoads: Set<UUID> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(document.sections) { section in
                sectionView(section)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func sectionView(_ section: SummarySection) -> some View {
        if !section.heading.isEmpty {
            inlineMarkdownText(section.heading)
                .font(.title3.bold())
                .padding(.top, 4)
        }

        ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
            blockView(block)
        }
    }

    @ViewBuilder
    private func blockView(_ block: SummaryBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inlineMarkdownText(text)
                .font(.body)
        case let .bulletedList(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inlineMarkdownText(item)
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
                        inlineMarkdownText(item)
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
                        inlineMarkdownText(item.text)
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
                inlineMarkdownText(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            .padding(.vertical, 2)
        case let .code(_, code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        case let .image(screenshotId, caption):
            imageView(screenshotId: screenshotId, caption: caption)
        case let .heading(level, text):
            headingView(level: level, text: text)
        case let .table(headers, rows):
            tableView(headers: headers, rows: rows)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        switch level {
        case 1, 2:
            inlineMarkdownText(text)
                .font(.title3.bold())
                .padding(.top, 4)
        case 3:
            inlineMarkdownText(text)
                .font(.headline)
                .padding(.top, 2)
        default:
            inlineMarkdownText(text)
                .font(.subheadline.bold())
                .padding(.top, 2)
        }
    }

    private func imageView(screenshotId: UUID, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = imageCache[screenshotId] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(L10n.summaryImageUnavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .onAppear {
                        guard !attemptedImageLoads.contains(screenshotId) else { return }
                        attemptedImageLoads.insert(screenshotId)
                        imageCache[screenshotId] = imageProvider(screenshotId)
                    }
            }

            if !caption.isEmpty {
                inlineMarkdownText(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(header)
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
                        inlineMarkdownText(cell)
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

    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        let displayText = Self.textByRemovingTranscriptLinks(text)
        if let attributed = try? AttributedString(
            markdown: displayText,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(displayText)
        }
    }

    private static func textByRemovingTranscriptLinks(_ text: String) -> String {
        let pattern = #"\[([^\]]+)\]\(transcript://[0-9]{2}:[0-9]{2}:[0-9]{2}\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var stripped = text
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: stripped),
                  let labelRange = Range(match.range(at: 1), in: stripped) else { continue }
            stripped.replaceSubrange(fullRange, with: String(stripped[labelRange]))
        }
        return stripped
    }
}
