import Foundation

/// 文字起こしテキストを LLM で要約し、Obsidian 互換の Markdown を生成するサービス。
enum SummaryService {
    struct GeneratedSummary {
        let document: SummaryDocument
        let fileName: String
        let markdown: String
        let renderedBody: String
    }

    /// 要約を生成し、Markdown と関連メタデータを返す。
    @MainActor
    static func generateSummary(
        projectURL: URL?,
        meetingId: UUID,
        createdAt: Date,
        transcriptText: String,
        noteText: String? = nil,
        screenshots: [MeetingScreenshotRecord] = [],
        recordingSessions: [RecordingSessionTimeline] = [],
        repository: MeetingRepository? = nil
    ) async throws -> GeneratedSummary {
        let settings = AppSettings.shared
        let endpoint = settings.resolvedLLMEndpointURL
        let model = settings.llmModelName
        let maxTokens = settings.llmMaxTokens
        let token = settings.llmAPIToken
        let prompt = resolvedSummaryPrompt(settings: settings, repository: repository)
        let languageName = settings.llmSummaryLanguage.displayName

        // メッセージ組み立て: テンプレート(system) → CONTEXT.md(user) → 文字起こし(user) + スクリーンショット
        let contextContent = projectURL.flatMap(readContext(in:))

        let structuredInstruction = """

        # Response Format
        Your response MUST be a JSON object with exactly four keys:
        - "title": a concise title for this meeting/transcript (one line, no quotes)
        - "sections": an array of summary body sections that exclude action items. Each section has:
          - "heading": the section heading, or an empty string for an intro section
          - "blocks": an array of content blocks in reading order
        - "tags": an array of relevant short Obsidian-compatible tags for categorization (empty array if none)
          - Tags MUST contain no spaces.
          - Tags MUST not be numeric-only.
          - Tags MUST use only letters, numbers, "_" and "-".
          - Use "_" or "-" to join words instead of spaces or punctuation.
          - Do not include "#", slashes, emojis, quotes, brackets, commas, or other symbols.
        - "action_items": the only location for action items; an array of objects with exactly two keys:
          - "title": the concrete action item
          - "assignee": who owns it, or an empty string if unclear

        Each block MUST be one object with all of these keys:
        - "type": one of "paragraph", "bulleted_list", "numbered_list", "checklist", "quote", "code", "image", "heading"
        - "level": heading level for "heading"; otherwise 0
        - "content": paragraph/quote/heading text, code body, or image caption; otherwise {"text":"","transcript_ref":null}
          - "content.text": the actual text
          - "content.transcript_ref": the most relevant HH:MM:SS timestamp for this text, or null
        - "items": list/checklist items; otherwise []
          - Each item has "text", "transcript_ref" as HH:MM:SS or null, and "checked" as true/false.
          - Use "checked": false for bulleted_list and numbered_list items.
        - "language": code language for "code"; otherwise empty string
        - "image_id": screenshot UUID for "image"; otherwise empty string

        Do not put transcript links inside text fields. Use content.transcript_ref or item.transcript_ref instead.
        Use inline Markdown only for emphasis and ordinary links inside text fields. Do not output tables; express them as lists.
        """
        let systemPrompt = prompt + "\n\n# Language\nWrite the summary in \(languageName)." + structuredInstruction
        var messages: [LLMService.ChatMessage] = [
            .init(role: "system", content: systemPrompt),
        ]
        if let contextContent {
            messages.append(.init(role: "user", content: contextContent))
        }

        var transcriptContent = "<meeting_id>\(meetingId.uuidString)</meeting_id>\n<transcript>\n\(transcriptText)\n</transcript>"
        if let noteText, !noteText.isEmpty {
            transcriptContent += "\n<note>\n\(noteText)\n</note>"
        }

        if screenshots.isEmpty {
            messages.append(.init(role: "user", content: transcriptContent))
        } else {
            // マルチモーダル: テキスト + スクリーンショット画像（MainActor 外でリサイズ・エンコード）
            let preparedImageDataURIs = await Task.detached(priority: .userInitiated) {
                screenshots.map { screenshot in
                    let imageData = ImageEncoder.resized(screenshot.imageData, maxLongEdge: 1024)
                    let mimeType = ImageEncoder.mimeType(for: imageData) ?? screenshot.mimeType
                    return "data:\(mimeType);base64,\(imageData.base64EncodedString())"
                }
            }.value
            var parts: [LLMService.ContentPart] = [.text(transcriptContent)]
            for (screenshot, preparedImageDataURI) in zip(screenshots, preparedImageDataURIs) {
                parts.append(.text(screenshotMetadata(for: screenshot, relativeTo: createdAt, recordingSessions: recordingSessions)))
                parts.append(.imageURL(preparedImageDataURI))
            }
            messages.append(.init(role: "user", parts: parts))
        }

        let responseText = try await LLMService.chatCompletion(
            endpoint: endpoint,
            model: model,
            token: token,
            messages: messages,
            maxTokens: maxTokens,
            responseFormat: SummaryDocumentResponse.responseFormat
        )

        let context = SummaryRenderContext(meetingId: meetingId, createdAt: createdAt, screenshots: screenshots)
        var document = decodeSummaryDocument(from: responseText, context: context)
        document.tags = resolvedTags(resultTags: document.tags, contextContent: contextContent)
        let rendered = ObsidianMarkdownSummaryRenderer.render(document: document, context: context)

        return GeneratedSummary(
            document: document,
            fileName: rendered.fileName,
            markdown: rendered.markdown,
            renderedBody: rendered.body
        )
    }

    static func screenshotMetadata(
        for screenshot: MeetingScreenshotRecord,
        relativeTo timeBase: Date,
        recordingSessions: [RecordingSessionTimeline] = []
    ) -> String {
        let time = Formatters.elapsedHHmmss(
            at: screenshot.capturedAt,
            sessionId: screenshot.sessionId,
            sessions: recordingSessions,
            fallbackTimeBase: timeBase
        )
        let imageFilename = ScreenshotExportService.filename(for: screenshot)
        return "<time>\(time)</time> <image_id>\(screenshot.id.uuidString)</image_id> <image_filename>\(imageFilename)</image_filename>"
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

    static func resolvedTags(resultTags: [String], contextContent: String?) -> [String] {
        var tags: [String] = []
        appendUniqueTags(resultTags, to: &tags)
        if let contextContent {
            appendUniqueTags(parseFrontmatterTags(from: contextContent), to: &tags)
        }
        return tags
    }

    private static let tagAllowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    private static let tagTrimCharacters = CharacterSet(charactersIn: "_-")

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
        let sections = response.sections
            .map { sectionDTO in
                SummarySection(
                    id: .v7(),
                    heading: LegacyMarkdownSummaryParser.normalizeInlineMarkdown(sectionDTO.heading),
                    blocks: sectionDTO.blocks.flatMap { blocks(from: $0, context: context) }
                )
            }
            .filter { !$0.heading.isEmpty || !$0.blocks.isEmpty }

        return SummaryDocument(
            title: LegacyMarkdownSummaryParser.normalizeInlineMarkdown(response.title),
            sections: sections,
            tags: response.tags,
            actionItems: normalizedActionItems(response.actionItems, context: context)
        )
    }

    private static func blocks(from dto: SummaryDocumentResponse.BlockDTO, context: SummaryRenderContext) -> [SummaryBlock] {
        let content = normalizedText(dto.content)

        switch dto.type {
        case "paragraph":
            return blocksByAttaching(content.transcriptRef, to: LegacyMarkdownSummaryParser.parseInlineBlocks(content.text, context: context))
        case "bulleted_list":
            let items = normalizedItemTexts(dto.items)
            return items.isEmpty ? [] : [.bulletedList(items: items)]
        case "numbered_list":
            let items = normalizedItemTexts(dto.items)
            return items.isEmpty ? [] : [.numberedList(items: items)]
        case "checklist":
            let items = normalizedChecklistItems(dto.items)
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
            return content.text.isEmpty ? [] : [.heading(
                level: max(3, dto.level),
                content: content
            )]
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
            .bulletedList(items: items.map { $0.withFallbackTranscriptRef(ref) })
        case let .numberedList(items):
            .numberedList(items: items.map { $0.withFallbackTranscriptRef(ref) })
        case let .checklist(items):
            .checklist(items: items.map { item in
                .init(text: item.text.withFallbackTranscriptRef(ref), checked: item.checked)
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

    private static func normalizedItemTexts(_ items: [SummaryDocumentResponse.ItemDTO]) -> [SummaryText] {
        items.compactMap(normalizedItemText)
    }

    private static func normalizedChecklistItems(_ items: [SummaryDocumentResponse.ItemDTO]) -> [SummaryBlock.ChecklistItem] {
        items.compactMap { item -> SummaryBlock.ChecklistItem? in
            guard let text = normalizedItemText(item) else { return nil }
            return SummaryBlock.ChecklistItem(
                text: text,
                checked: item.checked
            )
        }
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

    /// 選択中 instruction の内容を DB から解決する。
    /// Auto モード時はデフォルトプロンプト全体を返す。
    /// instruction 選択時は instruction 本文をそのまま使う。
    @MainActor
    static func resolvedSummaryPrompt(
        settings: AppSettings,
        repository: MeetingRepository? = nil
    ) -> String {
        // Auto モード
        guard let selectedInstructionID = settings.selectedInstructionID,
              let vaultId = settings.currentVault?.id else {
            return AppSettings.defaultSummaryPrompt
        }

        // カスタム instruction: DB から全文プロンプトを読み込む
        if let instruction = try? repository?.fetchInstruction(id: selectedInstructionID),
           instruction.vaultId == vaultId,
           !instruction.content.isEmpty {
            return instruction.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // フォールバック: デフォルト
        return AppSettings.defaultSummaryPrompt
    }

    /// プロジェクトフォルダ直下の CONTEXT.md を読み込む。存在しないか空なら nil。
    private static func readContext(in projectURL: URL) -> String? {
        let url = projectURL.appendingPathComponent("CONTEXT.md")
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              !content.isEmpty else {
            return nil
        }
        return content
    }

    /// YAML frontmatter から tags リストを抽出する。
    private static func parseFrontmatterTags(from text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)

        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return []
        }

        guard let closingIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return []
        }

        let frontmatterLines = lines[1 ..< closingIndex]

        guard let tagsLineIndex = frontmatterLines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "tags:"
        }) else {
            return []
        }

        var tags: [String] = []
        for line in frontmatterLines[frontmatterLines.index(after: tagsLineIndex)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { break }
            let tag = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty {
                tags.append(tag)
            }
        }
        return tags
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

        for scalar in candidate.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
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
