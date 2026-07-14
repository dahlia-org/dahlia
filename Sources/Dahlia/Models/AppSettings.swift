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

enum CalendarSource: String, CaseIterable, Identifiable {
    case google
    case macOS

    static let defaultEnabledSources: Set<CalendarSource> = [.google]
    static let defaultEnabledSourcesJSON = "[\"google\"]"
    nonisolated static let enabledSourcesUserDefaultsKey = "enabledCalendarSources"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: L10n.googleCalendar
        case .macOS: L10n.macOSCalendar
        }
    }
}

enum LLMProvider: String, CaseIterable, Identifiable {
    case openAI
    case databricks

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: L10n.openAI
        case .databricks: L10n.databricks
        }
    }
}

/// アプリ設定の一元管理。@AppStorage で UserDefaults に永続化。
@MainActor
final class AppSettings: ObservableObject, GoogleDriveExportFolderSettingsProviding {
    static let shared = AppSettings()
    nonisolated static let automaticScreenshotIntervalOptions = [
        5,
        10,
        20,
        30,
    ]
    nonisolated static let automaticScreenshotChangeThresholdPercentOptions = [
        5,
        10,
        20,
        30,
        50,
    ]
    nonisolated static let automaticScreenshotIntervalSecondsUserDefaultsKey = "automaticScreenshotIntervalSeconds"
    nonisolated static let automaticScreenshotChangeThresholdPercentUserDefaultsKey = "automaticScreenshotChangeThresholdPercent"
    nonisolated static let generateSummaryAfterBatchTranscriptionUserDefaultsKey = "generateSummaryAfterBatchTranscription"
    nonisolated static let defaultGoogleDriveExportFolderName = "Meeting Notes"
    fileprivate nonisolated static let defaultAutomaticScreenshotIntervalSeconds = 30
    fileprivate nonisolated static let defaultAutomaticScreenshotChangeThresholdPercent = 20
    nonisolated static let defaultLLMMaxTokens = 16000

    // MARK: - 表示言語

    @AppStorage(AppLanguage.userDefaultsKey) var appLanguageRawValue: String = AppLanguage.system.rawValue

    var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: appLanguageRawValue) ?? .system }
        set { appLanguageRawValue = newValue.rawValue }
    }

    // MARK: - Google Drive

    /// 変更可能だった試用版の保存先 ID を Meeting Notes として再利用しないため、旧フォルダ名も照合する。
    @AppStorage("googleDriveExportFolderName") private var storedGoogleDriveExportFolderName = AppSettings.defaultGoogleDriveExportFolderName
    @AppStorage("googleDriveExportFolderID") private var googleDriveExportFolderID = ""
    @AppStorage("googleDriveExportFolderAccountID") private var googleDriveExportFolderAccountID = ""

    func googleDriveExportFolderID(forAccountID accountID: String) -> String? {
        guard googleDriveExportFolderAccountID == accountID,
              storedGoogleDriveExportFolderName == Self.defaultGoogleDriveExportFolderName else { return nil }
        return googleDriveExportFolderID.nilIfBlank
    }

    func googleDriveExportFolderURL(forAccountID accountID: String) -> URL? {
        guard let folderID = googleDriveExportFolderID(forAccountID: accountID) else { return nil }
        return Self.googleDriveExportFolderURL(folderID: folderID)
    }

    nonisolated static func googleDriveExportFolderURL(folderID: String) -> URL? {
        guard !folderID.isEmpty,
              let baseURL = URL(string: "https://drive.google.com/drive/folders") else { return nil }
        return baseURL.appending(path: folderID)
    }

    func setGoogleDriveExportFolder(
        id: String,
        accountID: String
    ) {
        storedGoogleDriveExportFolderName = Self.defaultGoogleDriveExportFolderName
        googleDriveExportFolderID = id
        googleDriveExportFolderAccountID = accountID
    }

    func clearGoogleDriveExportFolderID(forAccountID accountID: String) {
        guard googleDriveExportFolderAccountID == accountID else { return }
        googleDriveExportFolderID = ""
    }

    // MARK: - 音声認識設定

    @AppStorage("transcriptionLocale") var transcriptionLocale: String = Locale.current.identifier
    @AppStorage(TranscriptionMode.userDefaultsKey) var transcriptionModeRawValue = TranscriptionMode.defaultMode.rawValue
    @AppStorage("retainAudioAfterBatchTranscription") var retainAudioAfterBatchTranscription = false
    @AppStorage(AppSettings.generateSummaryAfterBatchTranscriptionUserDefaultsKey) var generateSummaryAfterBatchTranscription = false
    @AppStorage("transcriptTranslationEnabled") var transcriptTranslationEnabled = true
    @AppStorage("transcriptTranslationTargetLanguage") var transcriptTranslationTargetLanguage = TranscriptTranslationLanguage.defaultIdentifier
    @AppStorage("liveSubtitleOverlayEnabled") var liveSubtitleOverlayEnabled = false
    @AppStorage("liveSubtitleOverlaySegmentCount") var liveSubtitleOverlaySegmentCount = 2
    @AppStorage("liveSubtitleSourceMode") var liveSubtitleSourceModeRawValue = LiveSubtitleSourceMode.includeMicrophone.rawValue
    @AppStorage("automaticScreenshotEnabled") var automaticScreenshotEnabled = true
    @AppStorage(AppSettings.automaticScreenshotIntervalSecondsUserDefaultsKey) private var storedAutomaticScreenshotIntervalSeconds =
        AppSettings.defaultAutomaticScreenshotIntervalSeconds
    @AppStorage(AppSettings.automaticScreenshotChangeThresholdPercentUserDefaultsKey) private var storedAutomaticScreenshotChangeThresholdPercent =
        AppSettings.defaultAutomaticScreenshotChangeThresholdPercent

    var transcriptionMode: TranscriptionMode {
        get { TranscriptionMode(rawValue: transcriptionModeRawValue) ?? .defaultMode }
        set { transcriptionModeRawValue = newValue.rawValue }
    }

    var isRealtimeTranscriptionEnabled: Bool {
        get { transcriptionMode == .realtime }
        set { transcriptionMode = newValue ? .realtime : .batch }
    }

    var automaticScreenshotIntervalSeconds: Int {
        get {
            Self.normalizedOption(
                storedAutomaticScreenshotIntervalSeconds,
                options: Self.automaticScreenshotIntervalOptions,
                defaultValue: Self.defaultAutomaticScreenshotIntervalSeconds
            )
        }
        set {
            storedAutomaticScreenshotIntervalSeconds = Self.normalizedOption(
                newValue,
                options: Self.automaticScreenshotIntervalOptions,
                defaultValue: Self.defaultAutomaticScreenshotIntervalSeconds
            )
        }
    }

    var automaticScreenshotChangeThresholdPercent: Int {
        get {
            Self.normalizedOption(
                storedAutomaticScreenshotChangeThresholdPercent,
                options: Self.automaticScreenshotChangeThresholdPercentOptions,
                defaultValue: Self.defaultAutomaticScreenshotChangeThresholdPercent
            )
        }
        set {
            storedAutomaticScreenshotChangeThresholdPercent = Self.normalizedOption(
                newValue,
                options: Self.automaticScreenshotChangeThresholdPercentOptions,
                defaultValue: Self.defaultAutomaticScreenshotChangeThresholdPercent
            )
        }
    }

    var automaticScreenshotChangeThresholdRatio: Double {
        Double(automaticScreenshotChangeThresholdPercent) / 100.0
    }

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

    private nonisolated static func normalizedOption(_ value: Int, options: [Int], defaultValue: Int) -> Int {
        guard !options.isEmpty else { return defaultValue }
        if options.contains(value) {
            return value
        }
        return options.first(where: { value <= $0 }) ?? options[options.count - 1]
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
    @AppStorage("microphoneMeetingNotificationsEnabled") var microphoneMeetingNotificationsEnabled = true
    @AppStorage("calendarEventMeetingNotificationsEnabled") var calendarEventMeetingNotificationsEnabled = false

    // MARK: - カレンダー設定

    @AppStorage("calendarSource") var calendarSourceRawValue = CalendarSource.google.rawValue
    @AppStorage(CalendarSource.enabledSourcesUserDefaultsKey) var enabledCalendarSourcesJSON = CalendarSource.defaultEnabledSourcesJSON
    @AppStorage("excludeAllDayCalendarEvents") var excludeAllDayCalendarEvents = true
    @AppStorage("excludeCalendarEventsWithoutOtherAttendees") var excludeCalendarEventsWithoutOtherAttendees = false
    @AppStorage("excludeCalendarEventsWithoutConferenceURI") var excludeCalendarEventsWithoutConferenceURI = false
    @AppStorage("excludeDeclinedCalendarEvents") var excludeDeclinedCalendarEvents = true
    @AppStorage("excludeOutOfOfficeCalendarEvents") var excludeOutOfOfficeCalendarEvents = true
    @AppStorage("menuBarCalendarEnabled") var menuBarCalendarEnabled = true
    @AppStorage("menuBarCalendarShowsEventTitle") var menuBarCalendarShowsEventTitle = true
    @AppStorage("menuBarCalendarShowsCountdown") var menuBarCalendarShowsCountdown = true
    nonisolated static let googleOAuthClientIDOverrideUserDefaultsKey = "googleOAuthClientIDOverride"
    nonisolated static let googleOAuthClientSecretOverrideKey = "googleOAuthClientSecretOverride"
    @AppStorage(AppSettings.googleOAuthClientIDOverrideUserDefaultsKey) var googleOAuthClientIDOverride = ""

    var calendarSource: CalendarSource {
        get { CalendarSource(rawValue: calendarSourceRawValue) ?? .google }
        set { calendarSourceRawValue = newValue.rawValue }
    }

    var calendarEventFilter: CalendarEventFilter {
        CalendarEventFilter(
            excludesAllDayEvents: excludeAllDayCalendarEvents,
            excludesEventsWithoutOtherAttendees: excludeCalendarEventsWithoutOtherAttendees,
            excludesEventsWithoutConferenceURI: excludeCalendarEventsWithoutConferenceURI,
            excludesDeclinedEvents: excludeDeclinedCalendarEvents,
            excludesOutOfOfficeEvents: excludeOutOfOfficeCalendarEvents
        )
    }

    var enabledCalendarSources: Set<CalendarSource> {
        get {
            let hasStoredEnabledSources = UserDefaults.standard.object(forKey: CalendarSource.enabledSourcesUserDefaultsKey) != nil

            if hasStoredEnabledSources,
               let sources = Self.decodeCalendarSources(from: enabledCalendarSourcesJSON) {
                return sources
            }

            if !hasStoredEnabledSources, let legacySource = CalendarSource(rawValue: calendarSourceRawValue) {
                return [legacySource]
            }

            return CalendarSource.defaultEnabledSources
        }
        set {
            enabledCalendarSourcesJSON = Self.encodeCalendarSources(newValue)
            if let firstSource = CalendarSource.allCases.first(where: { newValue.contains($0) }) {
                calendarSourceRawValue = firstSource.rawValue
            }
        }
    }

    func isCalendarSourceEnabled(_ source: CalendarSource) -> Bool {
        enabledCalendarSources.contains(source)
    }

    func setCalendarSource(_ source: CalendarSource, isEnabled: Bool) {
        var sources = enabledCalendarSources
        if isEnabled {
            sources.insert(source)
        } else {
            sources.remove(source)
        }
        enabledCalendarSources = sources
    }

    private static func decodeCalendarSources(from json: String) -> Set<CalendarSource>? {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let rawValues = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }

        let sources = rawValues.compactMap(CalendarSource.init(rawValue:))
        return Set(sources)
    }

    private static func encodeCalendarSources(_ sources: Set<CalendarSource>) -> String {
        let rawValues = CalendarSource.allCases
            .filter { sources.contains($0) }
            .map(\.rawValue)

        guard let data = try? JSONEncoder().encode(rawValues),
              let json = String(data: data, encoding: .utf8)
        else {
            return CalendarSource.defaultEnabledSourcesJSON
        }

        return json
    }

    /// Google OAuth client secret override（Keychain に保存）。
    var googleOAuthClientSecretOverride: String {
        get { KeychainService.load(key: Self.googleOAuthClientSecretOverrideKey, accessPolicy: .standard) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainService.delete(key: Self.googleOAuthClientSecretOverrideKey)
            } else {
                do {
                    try KeychainService.save(key: Self.googleOAuthClientSecretOverrideKey, value: trimmed, accessPolicy: .standard)
                } catch {
                    print("[KeychainService] Failed to save Google OAuth client secret override: \(error)")
                }
            }
            objectWillChange.send()
        }
    }

    // MARK: - LLM 設定

    @AppStorage("llmProvider") var llmProviderRawValue = ""
    @AppStorage("llmDatabricksWorkspaceURL") var llmDatabricksWorkspaceURL = ""
    @AppStorage("llmDatabricksAuthenticationType") var llmDatabricksAuthenticationTypeRawValue =
        DatabricksAuthenticationType.personalAccessToken.rawValue
    @AppStorage("llmDatabricksProfile") var llmDatabricksProfile = ""
    @AppStorage("llmModelName") var llmModelRawValue = LLMModel.defaultModel.rawValue
    @AppStorage("llmMaxTokens") private var storedLLMMaxTokens = AppSettings.defaultLLMMaxTokens
    @AppStorage("llmSummaryLanguage") var llmSummaryLanguageRawValue = SummaryLanguage.ja.rawValue

    var llmMaxTokens: Int {
        get { max(1, storedLLMMaxTokens) }
        set { storedLLMMaxTokens = max(1, newValue) }
    }

    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProviderRawValue) ?? .openAI }
        set { llmProviderRawValue = newValue.rawValue }
    }

    var llmDatabricksAuthenticationType: DatabricksAuthenticationType {
        get {
            DatabricksAuthenticationType(rawValue: llmDatabricksAuthenticationTypeRawValue)
                ?? .personalAccessToken
        }
        set { llmDatabricksAuthenticationTypeRawValue = newValue.rawValue }
    }

    var llmModel: LLMModel {
        get { LLMModel.fromPersistedValue(llmModelRawValue) ?? .defaultModel }
        set { llmModelRawValue = newValue.rawValue }
    }

    var resolvedLLMModelName: String {
        llmModel.identifier(for: llmProvider)
    }

    var resolvedLLMEndpointURL: String {
        switch llmProvider {
        case .openAI:
            return Self.openAIEndpointURL
        case .databricks:
            guard llmDatabricksAuthenticationType == .personalAccessToken else { return "" }
            return Self.databricksEndpointURL(workspaceURL: llmDatabricksWorkspaceURL) ?? ""
        }
    }

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
    - Output only the requested JSON object.
    - Build the summary as sections and typed content blocks.
    - Inline text fields may use Markdown for emphasis and links.
    - Keep the summary easy to scan.
      - Prefer headings and bullet points over long paragraphs.
      - Keep concrete action items out of summary sections; return them only in the top-level `action_items` array.
      - Do not invent facts.
    - Preserve uncertainty where the transcript is ambiguous.
    - Write in a casual yet professional tone.
    </output_policy>

    <citation_policy>
    - Support important claims with transcript references when possible.
    - Add transcript references to each relevant `content.transcript_ref` or `items[].transcript_ref` for key decisions, risks, dates, and open questions.
    - Do not over-cite to the point that readability suffers.
    </citation_policy>

    <rendering_rules>
    <transcript_links>
    - Do not put transcript links inside text fields.
    - When referencing the transcript for paragraph/quote/heading/code/image caption text, set that block's `content.transcript_ref`.
    - When referencing the transcript for a list or checklist item, set that item's `transcript_ref`.
    - Each transcript reference must be a single `HH:MM:SS` string, or null when there is no reference.
    - Use the most relevant timestamp for the referenced point.
    </transcript_links>
    <screenshot_embeds>
    - When referencing a screenshot, create an `image` block.
    - Set the image block's `image_id` to the exact provided `<image_id>` UUID.
    - Put any explanation in the image block's `text` caption.
    - Use the screenshot whose timestamp is closest to the referenced point.
    </screenshot_embeds>
    <tables>
    - Do not output tables. Express tabular information as concise lists.
    </tables>
    </rendering_rules>
    """

    /// Auto モード時のデフォルト Output Format セクション。
    private nonisolated static let defaultOutputFormat = """
    # Output Format

    <summary_template>
    - Treat each major heading as one section.
    - Do not add an Action Items section; return action items only in the top-level `action_items` array.
    - Add any other sections you think are necessary.
    </summary_template>
    """

    /// 完全なデフォルトプロンプト（preamble + defaultOutputFormat）。
    nonisolated static let defaultSummaryPrompt = summaryPromptPreamble + "\n\n" + defaultOutputFormat

    /// customer_meeting プリセットの Output Format セクション。
    nonisolated static let customerMeetingOutputFormat = """
    # Output Format
    Structure your response using the sections defined in <format>. Treat each heading as one section.

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
        switch (llmProvider, llmDatabricksAuthenticationType) {
        case (.openAI, _), (.databricks, .personalAccessToken):
            resolvedLLMEndpointURL.nilIfBlank != nil && llmAPIToken.nilIfBlank != nil
        case (.databricks, .oauthCLI):
            llmDatabricksProfile.nilIfBlank != nil
        }
    }

    nonisolated static let openAIEndpointURL = "https://api.openai.com/v1/chat/completions"

    nonisolated static func databricksEndpointURL(workspaceURL: String) -> String? {
        let trimmedURL = workspaceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedURL),
              components.scheme == "https",
              components.host?.isEmpty == false
        else {
            return nil
        }

        components.path = "/ai-gateway/mlflow/v1/chat/completions"
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    nonisolated static func resolvedDatabricksProfileSelection(
        current: String,
        availableProfiles: [String]
    ) -> String {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstAvailableProfile = availableProfiles.first else { return "" }
        return availableProfiles.contains(current) ? current : firstAvailableProfile
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

    @objc dynamic var liveSubtitleOverlaySegmentCount: Int {
        object(forKey: "liveSubtitleOverlaySegmentCount") as? Int ?? 2
    }

    @objc dynamic var liveSubtitleSourceMode: String? {
        string(forKey: "liveSubtitleSourceMode")
    }

    @objc dynamic var automaticScreenshotEnabled: Bool {
        object(forKey: "automaticScreenshotEnabled") as? Bool ?? true
    }

    @objc dynamic var automaticScreenshotIntervalSeconds: Int {
        object(forKey: AppSettings.automaticScreenshotIntervalSecondsUserDefaultsKey) as? Int
            ?? AppSettings.defaultAutomaticScreenshotIntervalSeconds
    }

    @objc dynamic var automaticScreenshotChangeThresholdPercent: Int {
        object(forKey: AppSettings.automaticScreenshotChangeThresholdPercentUserDefaultsKey) as? Int
            ?? AppSettings.defaultAutomaticScreenshotChangeThresholdPercent
    }

    @objc dynamic var calendarSource: String? {
        string(forKey: "calendarSource")
    }

    @objc dynamic var enabledCalendarSources: String? {
        string(forKey: CalendarSource.enabledSourcesUserDefaultsKey)
    }
}
