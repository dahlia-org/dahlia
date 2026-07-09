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
        let token = settings.llmAPIToken
        let prompt = resolvedSummaryPrompt(settings: settings, repository: repository)
        let languageName = settings.llmSummaryLanguage.displayName

        // メッセージ組み立て: テンプレート(system) → CONTEXT.md(user) → 文字起こし(user) + スクリーンショット
        let contextContent = projectURL.flatMap(readContext(in:))

        let structuredInstruction = """

        # Response Format
        Your response MUST be a JSON object with exactly four keys:
        - "title": a concise title for this meeting/transcript (one line, no quotes)
        - "sections": an array of sections. Each section has:
          - "heading": the section heading, or an empty string for an intro section
          - "blocks": an array of content blocks in reading order
        - "tags": an array of relevant short Obsidian-compatible tags for categorization (empty array if none)
          - Tags MUST contain no spaces.
          - Tags MUST not be numeric-only.
          - Tags MUST use only letters, numbers, "_" and "-".
          - Use "_" or "-" to join words instead of spaces or punctuation.
          - Do not include "#", slashes, emojis, quotes, brackets, commas, or other symbols.
        - "action_items": an array of objects with exactly two keys:
          - "title": the concrete action item
          - "assignee": who owns it, or an empty string if unclear

        Each block MUST be one object with all of these keys:
        - "type": one of "paragraph", "bulleted_list", "numbered_list", "checklist", "quote", "code", "image", "heading"
        - "level": heading level for "heading"; otherwise 0
        - "text": paragraph/quote/heading text, code body, or image caption; otherwise empty string
        - "items": list/checklist items; otherwise []
        - "language": code language for "code"; otherwise empty string
        - "image_id": screenshot UUID for "image"; otherwise empty string

        Use inline Markdown only inside text fields. Do not output tables; express them as lists.
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
            maxTokens: 16000,
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

    /// 要約保存先ディレクトリ内の `.md` ファイルを走査し、frontmatter の `meeting_id` が一致するファイルを返す。
    static func findSummaryFile(projectURL: URL?, vaultURL: URL, meetingId: UUID) -> URL? {
        let fm = FileManager.default
        let targetId = meetingId.uuidString.lowercased()
        let directoryURL = projectURL ?? vaultURL

        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "md" else { continue }
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 512),
                  let head = String(data: data, encoding: .utf8) else { continue }
            // frontmatter 内の meeting_id を case-insensitive で照合
            let lowered = head.lowercased()
            if lowered.contains("meeting_id:"),
               lowered.contains(targetId) {
                return fileURL
            }
        }
        return nil
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
        switch dto.type {
        case "paragraph":
            return LegacyMarkdownSummaryParser.parseInlineBlocks(dto.text, context: context)
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
            let text = LegacyMarkdownSummaryParser.normalizeInlineMarkdown(dto.text)
            return text.isEmpty ? [] : [.quote(text)]
        case "code":
            return [.code(language: dto.language, code: dto.text)]
        case "image":
            guard let screenshotId = UUID(uuidString: dto.imageId),
                  context.screenshots.contains(where: { $0.id == screenshotId }) else {
                return LegacyMarkdownSummaryParser.parseInlineBlocks(dto.text, context: context)
            }
            return [
                .image(
                    screenshotId: screenshotId,
                    caption: LegacyMarkdownSummaryParser.normalizeInlineMarkdown(dto.text)
                ),
            ]
        case "heading":
            let text = LegacyMarkdownSummaryParser.normalizeInlineMarkdown(dto.text)
            return text.isEmpty ? [] : [.heading(level: max(3, dto.level), text: text)]
        default:
            return LegacyMarkdownSummaryParser.parseInlineBlocks(dto.text, context: context)
        }
    }

    private static func normalizedItemTexts(_ items: [SummaryDocumentResponse.ItemDTO]) -> [String] {
        items
            .map { LegacyMarkdownSummaryParser.normalizeInlineMarkdown($0.text) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedChecklistItems(_ items: [SummaryDocumentResponse.ItemDTO]) -> [SummaryBlock.ChecklistItem] {
        items
            .map {
                SummaryBlock.ChecklistItem(
                    text: LegacyMarkdownSummaryParser.normalizeInlineMarkdown($0.text),
                    checked: $0.checked
                )
            }
            .filter { !$0.text.isEmpty }
    }

    private static func normalizedActionItems(
        _ actionItems: [SummaryActionItem],
        context: SummaryRenderContext
    ) -> [SummaryActionItem] {
        actionItems.map { item in
            let text = LegacyMarkdownSummaryParser.parseInlineBlocks(item.title, context: context)
                .compactMap { block -> String? in
                    switch block {
                    case let .paragraph(text):
                        text
                    case let .image(_, caption):
                        caption.nilIfBlank
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
