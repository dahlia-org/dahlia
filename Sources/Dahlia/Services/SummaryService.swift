import Foundation

/// 文字起こしテキストを LLM で要約し、Obsidian 互換の Markdown を生成するサービス。
enum SummaryService {
    struct GeneratedSummary {
        let fileName: String
        let markdown: String
        let title: String
        let summary: String
        let tags: [String]
        let actionItems: [SummaryActionItem]
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 要約を生成し、Markdown と関連メタデータを返す。
    @MainActor
    static func generateSummary(
        projectURL: URL?,
        meetingId: UUID,
        createdAt: Date,
        transcriptText: String,
        noteText: String? = nil,
        screenshots: [MeetingScreenshotRecord] = [],
        repository: MeetingRepository? = nil
    ) async throws -> GeneratedSummary {
        let settings = AppSettings.shared
        let endpoint = settings.llmEndpointURL
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
        - "summary": the full summary in Markdown format
        - "tags": an array of relevant short tags for categorization (empty array if none)
        - "action_items": an array of objects with exactly two keys:
          - "title": the concrete action item
          - "assignee": who owns it, or an empty string if unclear
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
                let time = timeFormatter.string(from: screenshot.capturedAt)
                let imageFilename = ScreenshotExportService.filename(for: screenshot)
                let imageMetadata = "<time>\(time)</time> <image_id>\(imageFilename)</image_id> <image_filename>\(imageFilename)</image_filename>"
                parts.append(.text(imageMetadata))
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
            responseFormat: SummaryResult.responseFormat
        )

        // Structured output のパース（フォールバック: プレーンテキストとして扱う）
        let result: SummaryResult = if let data = responseText.data(using: .utf8),
                                       let decoded = try? JSONDecoder().decode(SummaryResult.self, from: data) {
            decoded
        } else {
            SummaryResult(title: "", summary: responseText, tags: [])
        }

        let dateString = dateFormatter.string(from: createdAt)
        let tags = resolvedTags(resultTags: result.tags, contextContent: contextContent)
        let tagsYAML = tags.map { "  - \($0)" }.joined(separator: "\n")

        var frontmatterFields = """
        meeting_id: "\(meetingId.uuidString)"
        date: \(dateString)
        """
        if !result.title.isEmpty {
            let escapedTitle = result.title
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            frontmatterFields += "\ntitle: \"\(escapedTitle)\""
        }
        if !tags.isEmpty {
            frontmatterFields += "\ntags:\n\(tagsYAML)"
        }

        let frontmatter = "---\n\(frontmatterFields)\n---"

        let summary = normalizeScreenshotEmbeds(result.summary, screenshots: screenshots)
        let markdown = frontmatter + "\n\n" + summary + "\n"
        let fileName = summaryFileName(
            datePrefix: dateFormatter.string(from: createdAt),
            title: result.title,
            meetingId: meetingId
        ) + ".md"

        return GeneratedSummary(
            fileName: fileName,
            markdown: markdown,
            title: result.title,
            summary: summary,
            tags: tags,
            actionItems: result.actionItems
        )
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

    private static let obsidianImageEmbedRegex = try! NSRegularExpression(
        pattern: #"\!\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#
    )

    private static let obsidianLinkRegex = try! NSRegularExpression(
        pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#
    )

    static func normalizeScreenshotEmbeds(_ summary: String, screenshots: [MeetingScreenshotRecord]) -> String {
        guard !screenshots.isEmpty else { return summary }

        let matches = obsidianImageEmbedRegex.matches(in: summary, range: NSRange(summary.startIndex..., in: summary))
        guard !matches.isEmpty else { return summary }

        let filenamesById = Dictionary(
            screenshots.map { screenshot in
                (screenshot.id.uuidString.lowercased(), ScreenshotExportService.filename(for: screenshot))
            },
            uniquingKeysWith: { first, _ in first }
        )

        var normalized = summary
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: normalized),
                  let targetRange = Range(match.range(at: 1), in: normalized) else { continue }
            let target = String(normalized[targetRange])
            guard let filename = normalizedScreenshotFilename(for: target, filenamesById: filenamesById) else { continue }

            let replacement = if let aliasRange = Range(match.range(at: 2), in: normalized) {
                "![[\(filename)|\(normalized[aliasRange])]]"
            } else {
                "![[\(filename)]]"
            }
            normalized.replaceSubrange(fullRange, with: replacement)
        }

        return normalized
    }

    static func sanitizeDisplaySummary(_ summary: String) -> String {
        var sanitized = summary.replacingOccurrences(
            of: #"\!\[\[[^\]]+\]\]"#,
            with: "",
            options: .regularExpression
        )

        let linkRegex = obsidianLinkRegex
        let matches = linkRegex.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: sanitized) else { continue }
            let replacement = if let aliasRange = Range(match.range(at: 2), in: sanitized) {
                String(sanitized[aliasRange])
            } else {
                ""
            }
            sanitized.replaceSubrange(fullRange, with: replacement)
        }

        sanitized = sanitized.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"(?m)^[ \t]*[-*+]\s*$\n?"#, with: "", options: .regularExpression)
        sanitized = sanitized.replacingOccurrences(of: #"(?m)^[ \t]*[-*+]\s+\[[ xX]\]\s*$\n?"#, with: "", options: .regularExpression)

        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    private static func normalizedScreenshotFilename(for obsidianTarget: String, filenamesById: [String: String]) -> String? {
        let target = obsidianTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        let targetPath = target as NSString
        let directory = targetPath.deletingLastPathComponent
        let lastPathComponent = targetPath.lastPathComponent as NSString
        let id = lastPathComponent.deletingPathExtension.lowercased()
        guard let filename = filenamesById[id] else { return nil }

        return if directory.isEmpty || directory == "." {
            filename
        } else {
            "\(directory)/\(filename)"
        }
    }

    private static func summaryFileName(datePrefix: String, title: String, meetingId: UUID) -> String {
        guard !title.isEmpty else {
            return "\(datePrefix)-summary_\(meetingId.uuidString)"
        }
        let sanitized = title
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "", options: .regularExpression)
        return sanitized.isEmpty
            ? "\(datePrefix)-summary_\(meetingId.uuidString)"
            : "\(datePrefix)-\(sanitized)"
    }

    /// 選択中 instruction の内容を DB から解決する。
    /// Auto モード時はデフォルトプロンプト全体を返す。
    /// instruction 選択時は instruction 本文をそのまま使う。
    @MainActor
    static func resolvedSummaryPrompt(settings: AppSettings, repository: MeetingRepository? = nil) -> String {
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
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !tags.contains(trimmed) else { continue }
            tags.append(trimmed)
        }
    }
}
