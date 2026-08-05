import DahliaRuntimeSupport
import Foundation

/// Codex app-server で文字起こしを要約し、Obsidian 互換の Markdown を生成するサービス。
enum SummaryService {
    struct GeneratedSummary {
        let document: SummaryDocument
        let fileName: String
        let markdown: String
    }

    /// 要約を生成し、Markdown と関連メタデータを返す。
    @MainActor
    static func generateSummary(
        promptContext: SummaryPromptContext,
        transcriptText: String,
        noteText: String? = nil,
        screenshots: [MeetingScreenshotRecord] = [],
        recordingSessions: [RecordingSessionTimeline] = [],
        repository: MeetingRepository? = nil,
        generationSettings: SummaryGenerationSettings? = nil
    ) async throws -> GeneratedSummary {
        let generationSettings = generationSettings ?? .current()

        let systemPrompt = summaryGenerationInstructions(
            generationSettings: generationSettings,
            includesPreviousMeetings: !promptContext.previousMeetings.isEmpty
        )
        let inputs = await makeCodexInputs(.init(
            promptContext: promptContext,
            transcriptText: transcriptText,
            noteText: noteText,
            screenshots: screenshots,
            recordingSessions: recordingSessions
        ))

        let dahliaMCP = try dahliaMCPConfiguration(
            for: promptContext,
            repository: repository
        )

        let responseText = try await CodexAppServerService.shared.generate(.init(
            model: generationSettings.modelID,
            reasoningEffort: generationSettings.reasoningEffort,
            developerInstructions: systemPrompt,
            inputs: inputs,
            outputSchema: SummaryDocumentResponse.outputSchema,
            dahliaMCP: dahliaMCP
        ))

        let context = SummaryRenderContext(
            meetingId: promptContext.meetingId,
            createdAt: promptContext.recordedAt,
            screenshots: screenshots
        )
        var document = decodeSummaryDocument(from: responseText, context: context)
        document.tags = resolvedTags(document.tags)
        let rendered = ObsidianMarkdownSummaryRenderer.render(document: document, context: context)

        return GeneratedSummary(
            document: document,
            fileName: rendered.fileName,
            markdown: rendered.markdown
        )
    }

    /// DB に保存した Vault 相対パスから要約ファイルを解決する。
    static func findSummaryFile(
        storedRelativePath: String?,
        vaultURL: URL
    ) -> URL? {
        VaultSummaryFileLocator.findSummaryFile(
            storedRelativePath: storedRelativePath,
            vaultURL: vaultURL
        )
    }

    static func resolvedTags(_ resultTags: [String]) -> [String] {
        var tags: [String] = []
        appendUniqueTags(resultTags, to: &tags)
        return tags
    }

    private static let tagAllowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
    private static let tagTrimCharacters = CharacterSet(charactersIn: "_")

    static func decodeSummaryDocument(from responseText: String, context: SummaryRenderContext) -> SummaryDocument {
        guard let data = responseText.data(using: .utf8) else {
            return LegacyMarkdownSummaryParser.parse(markdown: responseText, context: context)
        }

        if let response = try? JSONDecoder().decode(SummaryDocumentResponse.self, from: data) {
            return document(from: response, context: context)
        }

        if let legacy = try? JSONDecoder().decode(SummaryResult.self, from: data) {
            var document = LegacyMarkdownSummaryParser.parse(
                markdown: legacy.summary,
                title: legacy.title,
                context: context
            )
            document.tags = legacy.tags
            document.actionItems = normalizedActionItems(legacy.actionItems, context: context)
            return document
        }

        return LegacyMarkdownSummaryParser.parse(markdown: responseText, context: context)
    }

    private static func document(from response: SummaryDocumentResponse, context: SummaryRenderContext) -> SummaryDocument {
        var remainingTableRenderCells = 1200
        var sections: [SummarySection] = []

        for sectionDTO in response.sections {
            var blocks: [SummaryBlock] = []
            for blockDTO in sectionDTO.blocks {
                blocks.append(contentsOf: self.blocks(
                    from: blockDTO,
                    context: context,
                    remainingTableRenderCells: &remainingTableRenderCells
                ))
            }

            let section = SummarySection(
                id: .v7(),
                heading: LegacyMarkdownSummaryParser.normalizeInlineMarkdown(sectionDTO.heading),
                blocks: blocks
            )
            if !section.heading.isEmpty || !section.blocks.isEmpty {
                sections.append(section)
            }
        }

        return SummaryDocument(
            schemaVersion: SummaryDocumentSchemaVersion.current,
            title: LegacyMarkdownSummaryParser.normalizeInlineMarkdown(response.title),
            description: normalizedDescription(response.description),
            sections: sections,
            tags: response.tags,
            actionItems: normalizedActionItems(response.actionItems, context: context)
        )
    }

    private static func normalizedDescription(_ value: String) -> String {
        let oneLine = value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(240))
    }

    private static func blocks(
        from dto: SummaryDocumentResponse.BlockDTO,
        context: SummaryRenderContext,
        remainingTableRenderCells: inout Int
    ) -> [SummaryBlock] {
        let content = normalizedText(dto.content)

        switch dto.type {
        case "paragraph":
            return blocksByAttaching(content.transcriptRef, to: LegacyMarkdownSummaryParser.parseInlineBlocks(content.text, context: context))
        case "bulleted_list":
            let items = normalizedItems(dto.items).map { item in
                SummaryListItem(text: item.text, indent: item.indent)
            }
            return items.isEmpty ? [] : [.bulletedList(items: items)]
        case "numbered_list":
            let items = normalizedItems(dto.items).map { item in
                SummaryListItem(text: item.text, indent: item.indent)
            }
            return items.isEmpty ? [] : [.numberedList(items: items)]
        case "checklist":
            let items = normalizedItems(dto.items).map { item in
                SummaryBlock.ChecklistItem(text: item.text, checked: item.checked, indent: item.indent)
            }
            return items.isEmpty ? [] : [.checklist(items: items)]
        case "quote":
            return content.text.isEmpty ? [] : [.quote(content)]
        case "code":
            let codeContent = SummaryText(
                dto.content.text,
                transcriptRef: normalizedTranscriptRef(dto.content.transcriptRef)
            )
            return codeContent.text.isEmpty ? [] : [.code(language: dto.language, content: codeContent)]
        case "image":
            guard let screenshotId = UUID(uuidString: dto.imageId),
                  context.screenshots.contains(where: { $0.id == screenshotId }) else {
                return blocksByAttaching(content.transcriptRef, to: LegacyMarkdownSummaryParser.parseInlineBlocks(content.text, context: context))
            }
            return [
                .image(
                    screenshotId: screenshotId,
                    caption: content
                ),
            ]
        case "heading":
            return content.text.isEmpty ? [] : [
                .heading(
                    level: max(3, dto.level),
                    content: content
                ),
            ]
        case "table":
            let columns = Array(dto.columns.prefix(12)).map { value in
                SummaryText(normalizedText(text: value, transcriptRef: nil).text)
            }
            guard !columns.isEmpty, remainingTableRenderCells >= columns.count else { return [] }

            let width = columns.count
            let rows = dto.rows.prefix(50).map { row -> [SummaryText] in
                var values = Array(row.prefix(width))
                values.append(contentsOf: repeatElement("", count: max(0, width - values.count)))
                return values.map { value in
                    SummaryText(normalizedText(text: value, transcriptRef: nil).text)
                }
            }
            let retainedRowCount = min(rows.count, (remainingTableRenderCells - width) / width)
            let retainedRows = Array(rows.prefix(retainedRowCount))
            remainingTableRenderCells -= width * (1 + retainedRows.count)
            return [.table(headers: columns, rows: retainedRows)]
        default:
            return blocksByAttaching(content.transcriptRef, to: LegacyMarkdownSummaryParser.parseInlineBlocks(content.text, context: context))
        }
    }

    private static func blocksByAttaching(_ ref: TranscriptReference?, to blocks: [SummaryBlock]) -> [SummaryBlock] {
        guard let ref else { return blocks }

        return blocks.map { block in
            SummaryBlock(id: block.id, content: contentByAttaching(ref, to: block.content))
        }
    }

    private static func contentByAttaching(_ ref: TranscriptReference, to content: SummaryBlockContent) -> SummaryBlockContent {
        switch content {
        case let .paragraph(text):
            .paragraph(text.withFallbackTranscriptRef(ref))
        case let .bulletedList(items):
            .bulletedList(items: items.map { item in
                SummaryListItem(text: item.text.withFallbackTranscriptRef(ref), indent: item.indent)
            })
        case let .numberedList(items):
            .numberedList(items: items.map { item in
                SummaryListItem(text: item.text.withFallbackTranscriptRef(ref), indent: item.indent)
            })
        case let .checklist(items):
            .checklist(items: items.map { item in
                .init(text: item.text.withFallbackTranscriptRef(ref), checked: item.checked, indent: item.indent)
            })
        case let .quote(text):
            .quote(text.withFallbackTranscriptRef(ref))
        case let .code(language, text):
            .code(language: language, content: text.withFallbackTranscriptRef(ref))
        case let .image(screenshotId, caption):
            .image(screenshotId: screenshotId, caption: caption.withFallbackTranscriptRef(ref))
        case let .heading(level, text):
            .heading(level: level, content: text.withFallbackTranscriptRef(ref))
        case let .table(headers, rows):
            .table(
                headers: headers.map { $0.withFallbackTranscriptRef(ref) },
                rows: rows.map { $0.map { $0.withFallbackTranscriptRef(ref) } }
            )
        }
    }

    private static func normalizedItems(
        _ items: [SummaryDocumentResponse.ItemDTO]
    ) -> [(text: SummaryText, checked: Bool, indent: Int)] {
        var normalized = items.compactMap { item -> (text: SummaryText, checked: Bool, indent: Int)? in
            guard let text = normalizedItemText(item) else { return nil }
            return (
                text: text,
                checked: item.checked,
                indent: min(max(item.indent, 0), 2)
            )
        }

        for index in normalized.indices {
            if index == normalized.startIndex {
                normalized[index].indent = 0
            } else {
                normalized[index].indent = min(normalized[index].indent, normalized[index - 1].indent + 1)
            }
        }
        return normalized
    }

    private static func normalizedItemText(_ item: SummaryDocumentResponse.ItemDTO) -> SummaryText? {
        let text = normalizedText(text: item.text, transcriptRef: item.transcriptRef)
        return text.text.nilIfBlank.map { SummaryText($0, transcriptRef: text.transcriptRef) }
    }

    private static func normalizedText(_ dto: SummaryDocumentResponse.TextDTO) -> SummaryText {
        normalizedText(text: dto.text, transcriptRef: dto.transcriptRef)
    }

    private static func normalizedText(text: String, transcriptRef: String?) -> SummaryText {
        let normalized = LegacyMarkdownSummaryParser.normalizedTextAndRefs(text)
        return SummaryText(
            normalized.text,
            transcriptRef: normalizedTranscriptRef(transcriptRef) ?? normalized.refs.first
        )
    }

    private static func normalizedTranscriptRef(_ ref: String?) -> TranscriptReference? {
        guard let time = ref?.nilIfBlank,
              time.firstMatch(of: /^\d{2}:\d{2}:\d{2}$/) != nil else {
            return nil
        }
        return TranscriptReference(time: time)
    }

    private static func normalizedActionItems(
        _ actionItems: [SummaryActionItem],
        context: SummaryRenderContext
    ) -> [SummaryActionItem] {
        actionItems.map { item in
            let text = LegacyMarkdownSummaryParser.parseInlineBlocks(item.title, context: context)
                .compactMap { block -> String? in
                    switch block.content {
                    case let .paragraph(text):
                        text.text
                    case let .image(_, caption):
                        caption.text.nilIfBlank
                    default:
                        nil
                    }
                }
                .joined(separator: " ")
            return SummaryActionItem(
                title: text.nilIfBlank ?? LegacyMarkdownSummaryParser.normalizeInlineMarkdown(item.title),
                assignee: item.assignee
            )
        }
    }

    // MARK: - Private Helpers

    @MainActor
    static func summaryGenerationInstructions(
        settings: AppSettings,
        includesPreviousMeetings: Bool
    ) -> String {
        summaryGenerationInstructions(
            generationSettings: .current(settings),
            includesPreviousMeetings: includesPreviousMeetings
        )
    }

    static func summaryGenerationInstructions(
        generationSettings: SummaryGenerationSettings,
        includesPreviousMeetings: Bool
    ) -> String {
        // カスタム instruction は一時的に無効化し、保存済みの選択にかかわらず既定値を使う。
        var sections = [
            AppSettings.defaultSummaryPrompt,
            codexInputTrustInstruction,
        ]
        if includesPreviousMeetings {
            sections.append(codexPreviousMeetingsInstruction)
        }
        sections.append("# Detail Level\n\(generationSettings.detailLevelInstruction)")
        sections.append("# Language\nWrite the summary in \(generationSettings.languageDisplayName).")
        return sections.joined(separator: "\n\n") + codexStructuredInstruction
    }

    private static func appendUniqueTags(_ candidates: [String], to tags: inout [String]) {
        for candidate in candidates {
            guard let tag = normalizedTag(candidate), !tags.contains(tag) else { continue }
            tags.append(tag)
        }
    }

    private static func normalizedTag(_ candidate: String) -> String? {
        var normalized = ""
        var lastWasSeparator = false

        for scalar in candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            if tagAllowedCharacters.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                normalized.append("_")
                lastWasSeparator = true
            }
        }

        let tag = normalized.trimmingCharacters(in: tagTrimCharacters)
        guard tag.contains(where: { !$0.isNumber }) else { return nil }
        return tag
    }

}

private extension SummaryText {
    func withFallbackTranscriptRef(_ ref: TranscriptReference) -> SummaryText {
        SummaryText(text, transcriptRef: transcriptRef ?? ref)
    }
}
