import Combine
import SwiftUI

/// アプリの表示言語。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case ja
    case en

    /// UserDefaults キー。
    nonisolated static let userDefaultsKey = "appLanguage"

    var id: String { rawValue }

    /// ピッカーに表示する名前（各言語のネイティブ名）。
    var displayName: String {
        switch self {
        case .system: L10n.followSystem
        case .ja: "日本語"
        case .en: "English"
        }
    }

    /// 対応する lproj リソース名。system の場合は nil。
    var lprojName: String? {
        switch self {
        case .system: nil
        case .ja: "ja"
        case .en: "en"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            .current
        case .ja:
            Locale(identifier: "ja")
        case .en:
            Locale(identifier: "en")
        }
    }
}

/// アプリ設定の一元管理。@AppStorage で UserDefaults に永続化。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    nonisolated static let defaultAgentLaunchCommand = "claude"

    // MARK: - 表示言語

    @AppStorage(AppLanguage.userDefaultsKey) var appLanguageRawValue: String = AppLanguage.system.rawValue

    var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: appLanguageRawValue) ?? .system }
        set { appLanguageRawValue = newValue.rawValue }
    }

    // MARK: - 音声認識設定

    @AppStorage("transcriptionLocale") var transcriptionLocale: String = Locale.current.identifier
    @AppStorage("transcriptTranslationEnabled") var transcriptTranslationEnabled = true
    @AppStorage("transcriptTranslationTargetLanguage") var transcriptTranslationTargetLanguage = TranscriptTranslationLanguage.defaultIdentifier
    @AppStorage("liveSubtitleOverlayEnabled") var liveSubtitleOverlayEnabled = false
    @AppStorage("liveSubtitleOverlaySegmentCount") var liveSubtitleOverlaySegmentCount = 2
    @AppStorage("liveSubtitleSourceMode") var liveSubtitleSourceModeRawValue = LiveSubtitleSourceMode.includeMicrophone.rawValue

    var liveSubtitleSourceMode: LiveSubtitleSourceMode {
        get { LiveSubtitleSourceMode(rawValue: liveSubtitleSourceModeRawValue) ?? .includeMicrophone }
        set { liveSubtitleSourceModeRawValue = newValue.rawValue }
    }

    var isTranscriptTranslationEffectivelyEnabled: Bool {
        transcriptTranslationEnabled && TranscriptTranslationLanguage.shouldTranslate(
            transcriptionLocaleIdentifier: transcriptionLocale,
            targetLanguageIdentifier: transcriptTranslationTargetLanguage
        )
    }

    // MARK: - 表示言語設定

    /// デフォルトで有効にする言語識別子のJSON。
    private static let defaultEnabledLocalesJSON = "[\"en_US\",\"ja_JP\"]"

    /// 言語選択ピッカーに表示する言語の識別子（JSON配列）。
    @AppStorage("enabledLocaleIdentifiers") var enabledLocaleIdentifiersJSON = defaultEnabledLocalesJSON

    var enabledLocaleIdentifiers: Set<String> {
        get {
            guard !enabledLocaleIdentifiersJSON.isEmpty,
                  let data = enabledLocaleIdentifiersJSON.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(array)
        }
        set {
            if newValue.isEmpty {
                enabledLocaleIdentifiersJSON = ""
            } else {
                let array = Array(newValue).sorted()
                if let data = try? JSONEncoder().encode(array),
                   let json = String(data: data, encoding: .utf8) {
                    enabledLocaleIdentifiersJSON = json
                }
            }
        }
    }

    /// 指定ロケールが有効かどうか。空の場合は全て有効。
    func isLocaleEnabled(_ identifier: String) -> Bool {
        let enabled = enabledLocaleIdentifiers
        return enabled.isEmpty || enabled.contains(identifier)
    }

    // MARK: - 保管庫（ランタイム状態）

    /// 現在開いている保管庫。DB の `vaults` テーブルから選択される。
    @Published var currentVault: VaultRecord?

    /// 現在の保管庫の URL。保管庫未選択時は nil。
    var vaultURL: URL? {
        currentVault?.url
    }

    // MARK: - 会議検出設定

    @AppStorage("meetingDetectionEnabled") var meetingDetectionEnabled = true

    // MARK: - Agent 設定

    @AppStorage("agentLaunchCommand") var agentLaunchCommand = AppSettings.defaultAgentLaunchCommand
    @AppStorage("agentPermissionMode") var agentPermissionModeRawValue = AgentPermissionMode.auto.rawValue
    @AppStorage("agentAllowedTools") var agentAllowedTools = AgentService.defaultAllowedTools

    var agentPermissionMode: AgentPermissionMode {
        get { AgentPermissionMode(rawValue: agentPermissionModeRawValue) ?? .auto }
        set { agentPermissionModeRawValue = newValue.rawValue }
    }

    // MARK: - LLM 設定

    @AppStorage("llmEndpointURL") var llmEndpointURL = ""
    @AppStorage("llmModelName") var llmModelName = ""
    @AppStorage("llmAutoSummaryEnabled") var llmAutoSummaryEnabled = false
    @AppStorage("llmSummaryLanguage") var llmSummaryLanguageRawValue = SummaryLanguage.ja.rawValue

    var llmSummaryLanguage: SummaryLanguage {
        get { SummaryLanguage(rawValue: llmSummaryLanguageRawValue) ?? .ja }
        set { llmSummaryLanguageRawValue = newValue.rawValue }
    }

    @AppStorage("llmSummaryPrompt") var llmSummaryPrompt: String = AppSettings.defaultSummaryPrompt
    @AppStorage("selectedInstructionID") var selectedInstructionIDRawValue = AppSettings.autoInstructionRawValue

    var selectedInstructionID: UUID? {
        get { UUID(uuidString: selectedInstructionIDRawValue) }
        set { selectedInstructionIDRawValue = newValue?.uuidString ?? Self.autoInstructionRawValue }
    }

    /// Auto モードを示す instruction 選択値（空文字列）。
    nonisolated static let autoInstructionRawValue = ""

    /// プリセットテンプレート名と内容のマッピング（Output Format セクションのみ）。
    nonisolated static let presetTemplates: [String: String] = [
        "customer_meeting": customerMeetingOutputFormat,
    ]

    // MARK: - Summary Prompt 定数

    /// ベースプロンプト（`# Output Format` より前の共通部分）。
    private nonisolated static let summaryPromptPreamble = """
    # Role and Objective
    <task>
    You are a meeting analyst. Extract a structured summary from the provided <transcript>.
    </task>

    <output_policy>
    - Output only the summary body.
    - Use Markdown.
    - Keep the summary easy to scan.
      - Prefer headings and bullet points over long paragraphs.
      - Use checkboxes only for concrete action items.
      - Do not invent facts.
    - Preserve uncertainty where the transcript is ambiguous.
    - Write in a casual yet professional tone.
    </output_policy>

    <citation_policy>
    - Support important claims with transcript references when possible.
    - Add transcript links inline for key decisions, action items, risks, dates, and open questions.
    - Do not over-cite to the point that readability suffers.
    </citation_policy>

    <rendering_rules>
    <transcript_links>
    - When referencing the transcript, use the format `([[<transcript_id>#HH:MM:SS|HH:MM:SS]])`.
    - Use the most relevant timestamp for the referenced point.
    </transcript_links>
    <screenshot_embeds>
    - When referencing a screenshot, embed it using the format `![[<image_filename>]]`.
    - Use the exact provided image filename, including its file extension.
    - Example: `![[019E61FD-B5D6-7A04-AC25-4B820FE951E6.jpeg]]`.
    - Use the screenshot whose timestamp is closest to the referenced point.
    </screenshot_embeds>
    </rendering_rules>
    """

    /// Auto モード時のデフォルト Output Format セクション。
    private nonisolated static let defaultOutputFormat = """
    # Output Format

    <summary_template>
    - List action items if there are any.
    - Add any other sections you think are necessary.
    </summary_template>
    """

    /// 完全なデフォルトプロンプト（preamble + defaultOutputFormat）。
    nonisolated static let defaultSummaryPrompt = summaryPromptPreamble + "\n\n" + defaultOutputFormat

    /// customer_meeting プリセットの Output Format セクション。
    nonisolated static let customerMeetingOutputFormat = """
    # Output Format
    Use Markdown for all output. Structure your response using the sections defined in <format>.

    <format>
    ### 次のステップ
    会話の内容に基づいて、次のステップが何かを整理してください。もし日付が出ていれば、それも含めて記載すること。

    ### 要点・決定事項
    議論の要点や決定事項を整理してください。

    ### 進捗
    進行中の案件やプロジェクトについて整理してください。前回のミーティングからの進捗や、タスクや期限の変更があれば記載します。

    ### 課題・懸念点
    ミーティング中に挙がった課題や懸念点をまとめてください。特に、フォローアップが必要な内容を重点的にリストアップします。
    </format>
    """

    /// LLM の接続設定が揃っているかどうか。
    var isLLMConfigComplete: Bool {
        !llmEndpointURL.isEmpty && !llmModelName.isEmpty && !llmAPIToken.isEmpty
    }

    /// API トークン（Keychain に保存）。
    var llmAPIToken: String {
        get { KeychainService.load(key: "llmAPIToken") ?? "" }
        set {
            if newValue.isEmpty {
                KeychainService.delete(key: "llmAPIToken")
            } else {
                do {
                    try KeychainService.save(key: "llmAPIToken", value: newValue)
                } catch {
                    print("[KeychainService] Failed to save API token: \(error)")
                }
            }
            objectWillChange.send()
        }
    }
}

// MARK: - UserDefaults KVO キーパス

extension UserDefaults {
    /// NOTE: KVO を正しく動作させるため、プロパティ名を UserDefaults キー名と一致させる
    @objc dynamic var transcriptionLocale: String? {
        string(forKey: "transcriptionLocale")
    }

    @objc dynamic var enabledLocaleIdentifiers: String? {
        string(forKey: "enabledLocaleIdentifiers")
    }

    @objc dynamic var transcriptTranslationEnabled: Bool {
        object(forKey: "transcriptTranslationEnabled") as? Bool ?? true
    }

    @objc dynamic var transcriptTranslationTargetLanguage: String? {
        string(forKey: "transcriptTranslationTargetLanguage")
    }

    @objc dynamic var liveSubtitleOverlayEnabled: Bool {
        bool(forKey: "liveSubtitleOverlayEnabled")
    }

    @objc dynamic var llmAutoSummaryEnabled: Bool {
        bool(forKey: "llmAutoSummaryEnabled")
    }
}
