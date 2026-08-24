// Localized accessors intentionally remain in one namespace for discoverability and key parity.
// swiftlint:disable file_length

import Foundation

/// ローカライズ文字列への型安全なアクセスを提供する。
enum L10n {
    /// キャッシュ済みの Bundle と、その生成元の言語 rawValue。
    /// 言語設定が変わらない限り Bundle を再生成しない。
    private nonisolated(unsafe) static var cachedBundle: Bundle = .appModule
    private nonisolated(unsafe) static var cachedLanguageRaw = ""

    /// 選択された表示言語に対応する Bundle を返す。
    /// UserDefaults から直接読み取ることで @MainActor 制約を回避する。
    private nonisolated static var bundle: Bundle {
        let rawValue = UserDefaults.standard.string(forKey: AppLanguage.userDefaultsKey) ?? AppLanguage.system.rawValue
        if rawValue == cachedLanguageRaw {
            return cachedBundle
        }
        let resolved: Bundle = if let language = AppLanguage(rawValue: rawValue),
                                  let lprojName = language.lprojName,
                                  let path = Bundle.appModule.path(forResource: lprojName, ofType: "lproj"),
                                  let lprojBundle = Bundle(path: path) {
            lprojBundle
        } else {
            .appModule
        }
        cachedLanguageRaw = rawValue
        cachedBundle = resolved
        return resolved
    }

    // MARK: - Common

    static var delete: String { String(localized: "Delete", bundle: bundle) }
    static var remove: String { String(localized: "Remove", bundle: bundle) }
    static var removeProjectAssignment: String { String(localized: "Remove from Project", bundle: bundle) }
    static var rename: String { String(localized: "Rename", bundle: bundle) }
    static var retry: String { String(localized: "Retry", bundle: bundle) }
    static var create: String { String(localized: "Create", bundle: bundle) }
    static var auto: String { String(localized: "Auto", bundle: bundle) }
    static var apply: String { String(localized: "Apply", bundle: bundle) }
    static var clear: String { String(localized: "Clear", bundle: bundle) }
    static var edit: String { String(localized: "Edit", bundle: bundle) }
    static var reload: String { String(localized: "Reload", bundle: bundle) }
    static var close: String { String(localized: "Close", bundle: bundle) }
    static var copyImage: String { String(localized: "Copy Image", bundle: bundle) }
    static var previousImage: String { String(localized: "Previous Image", bundle: bundle) }
    static var nextImage: String { String(localized: "Next Image", bundle: bundle) }
    static var done: String { String(localized: "Done", bundle: bundle) }
    static var select: String { String(localized: "Select", bundle: bundle) }
    static var selectAll: String { String(localized: "Select All", bundle: bundle) }
    static var download: String { String(localized: "Download", bundle: bundle) }
    static var imageInformation: String { String(localized: "Image Information", bundle: bundle) }
    static var capturedAt: String { String(localized: "Captured", bundle: bundle) }
    static var fileType: String { String(localized: "File Type", bundle: bundle) }
    static var fileSize: String { String(localized: "File Size", bundle: bundle) }
    static var imageDimensions: String { String(localized: "Dimensions", bundle: bundle) }
    static var layout: String { String(localized: "Layout", bundle: bundle) }
    static var large: String { String(localized: "Large", bundle: bundle) }
    static var medium: String { String(localized: "Medium", bundle: bundle) }
    static var small: String { String(localized: "Small", bundle: bundle) }
    static var deleteSelectedScreenshotsConfirmation: String { String(
        localized: "The selected screenshots will be permanently deleted. Screenshots used in the summary are protected.",
        bundle: bundle
    ) }
    static var screenshotUsedInSummary: String { String(localized: "Used in summary", bundle: bundle) }

    static func enlargeScreenshot(caption: String?) -> String {
        guard let caption else {
            return String(localized: "Enlarge screenshot", bundle: bundle)
        }
        return String(localized: "Enlarge screenshot: \(caption)", bundle: bundle)
    }

    static var search: String { String(localized: "Search", bundle: bundle) }
    static var searchResults: String { String(localized: "Search Results", bundle: bundle) }
    static var searchQueryTooBroad: String { String(localized: "Search query is too broad", bundle: bundle) }
    static var fullTextSearch: String { String(localized: "Full-text search", bundle: bundle) }
    static var vectorSearch: String { String(localized: "Vector search", bundle: bundle) }
    static var enableVectorSearch: String { String(localized: "Enable vector search", bundle: bundle) }
    static var searchIndexStatus: String { String(localized: "Search index status", bundle: bundle) }
    static var searchQueuePending: String { String(localized: "Pending search jobs", bundle: bundle) }
    static var searchQueueProcessing: String { String(localized: "Processing search jobs", bundle: bundle) }
    static var searchIndexProgress: String { String(localized: "Indexing progress", bundle: bundle) }
    static var searchIndexDescription: String { String(localized: "Search index description", bundle: bundle) }
    static var semanticMatch: String { String(localized: "Semantic match", bundle: bundle) }
    static var neuralModelRequired: String { String(localized: "Neural model required", bundle: bundle) }
    static var neuralIndexNotReady: String { String(localized: "Neural index not ready", bundle: bundle) }
    static var neuralSearchFailed: String { String(localized: "Neural search failed", bundle: bundle) }
    static var embeddingModel: String { String(localized: "Embedding model", bundle: bundle) }
    static var installed: String { String(localized: "Installed", bundle: bundle) }
    static var notInstalled: String { String(localized: "Not installed", bundle: bundle) }
    static var vectorIndexStatus: String { String(localized: "Vector index status", bundle: bundle) }
    static var downloadingEmbeddingModel: String { String(localized: "Downloading embedding model", bundle: bundle) }
    static var acceptTermsAndDownloadModel: String {
        String(localized: "Accept terms and download model", bundle: bundle)
    }

    static var gemmaTerms: String { String(localized: "Gemma terms", bundle: bundle) }
    static var embeddingModelDescription: String {
        String(localized: "Embedding model description", bundle: bundle)
    }

    static var searchRanking: String { String(localized: "Search ranking", bundle: bundle) }
    static var searchRankingDescription: String { String(localized: "Search ranking description", bundle: bundle) }
    static var searchRankingPreset: String { String(localized: "Ranking preset", bundle: bundle) }
    static var searchRankingPresetStandard: String { String(localized: "Ranking preset standard", bundle: bundle) }
    static var searchRankingPresetTitleAndTags: String {
        String(localized: "Ranking preset title and tags", bundle: bundle)
    }

    static var searchRankingPresetContent: String { String(localized: "Ranking preset content", bundle: bundle) }
    static var searchRankingPresetCustom: String { String(localized: "Ranking preset custom", bundle: bundle) }
    static var searchRankingFieldExcluded: String { String(localized: "Excluded from search", bundle: bundle) }

    static func searchRankingWeight(_ weight: Double) -> String {
        String(format: "%.1f", weight)
    }

    static var searchBenchmark: String { String(localized: "Search benchmark", bundle: bundle) }
    static var searchBenchmarkDescription: String { String(localized: "Search benchmark description", bundle: bundle) }
    static var searchBenchmarkRun: String { String(localized: "Run benchmark", bundle: bundle) }
    static var searchBenchmarkReevaluate: String { String(localized: "Re-evaluate", bundle: bundle) }
    static var searchBenchmarkGenerating: String { String(localized: "Building the evaluation set", bundle: bundle) }
    static var searchBenchmarkEvaluating: String { String(localized: "Scoring ranking weights", bundle: bundle) }
    static var searchBenchmarkQueryCount: String { String(localized: "Evaluated queries", bundle: bundle) }
    static var searchBenchmarkCurrentScore: String { String(localized: "Current weights", bundle: bundle) }
    static var searchBenchmarkScoreFormat: String { String(localized: "Benchmark score format", bundle: bundle) }
    static var searchBenchmarkRecommendationFormat: String {
        String(localized: "Benchmark recommendation format", bundle: bundle)
    }

    static var searchBenchmarkApplyRecommendation: String { String(localized: "Apply recommended", bundle: bundle) }
    static var searchBenchmarkCurrentIsBest: String { String(localized: "Benchmark current is best", bundle: bundle) }
    static var searchBenchmarkNeedsMeetings: String { String(localized: "Benchmark needs meetings", bundle: bundle) }
    static var searchBenchmarkNoJudgments: String { String(localized: "Benchmark no judgments", bundle: bundle) }

    static var rebuildFullTextSearch: String { String(localized: "Rebuild full-text search", bundle: bundle) }
    static var rebuildVectorSearch: String { String(localized: "Rebuild vector search", bundle: bundle) }

    static var searchIndexPending: String { String(localized: "Search index pending", bundle: bundle) }
    static var searchIndexMetadata: String { String(localized: "Indexing meeting metadata", bundle: bundle) }
    static var searchIndexReady: String { String(localized: "Search index ready", bundle: bundle) }
    static var searchIndexFailed: String { String(localized: "Search index failed", bundle: bundle) }
    static var searchIndexErrorFormat: String { String(localized: "Search index error format", bundle: bundle) }
    static var actions: String { String(localized: "Actions", bundle: bundle) }
    static var status: String { String(localized: "Status", bundle: bundle) }
    static var customerIntelligenceContactNameRequired: String {
        String(localized: "Enter a contact name.", bundle: bundle)
    }

    static var dahlia: String { String(localized: "Dahlia", bundle: bundle) }
    static var anotherDahliaInstanceTitle: String { String(localized: "Dahlia Is Already Running", bundle: bundle) }
    static var anotherDahliaInstanceMessage: String { String(
        localized: "Another Dahlia process is already using the recording database. This process will now quit.",
        bundle: bundle
    ) }
    static var recordingStorageUnavailable: String { String(
        localized: "The recording storage is unavailable.",
        bundle: bundle
    ) }
    static var recordingAudioSessionActive: String { String(
        localized: "The recording is still active and cannot be changed.",
        bundle: bundle
    ) }
    static var recordingAudioAmbiguous: String { String(
        localized: "Multiple recording files exist and Dahlia cannot safely choose one.",
        bundle: bundle
    ) }
    static var recordingAudioDiskSpaceLow: String { String(
        localized: "Recording stopped because less than 1 GB of safe disk space remains.",
        bundle: bundle
    ) }
    static var recordingAudioIntegrityMismatch: String { String(
        localized: "The recording failed its integrity check.",
        bundle: bundle
    ) }
    static var recordingAudioInvalidPath: String { String(
        localized: "Dahlia refused an unsafe recording file path.",
        bundle: bundle
    ) }
    static var recordingAudioInvalidState: String { String(
        localized: "The recording is not in a state that allows this operation.",
        bundle: bundle
    ) }
    static var recordingAudioMissingSessionLease: String { String(
        localized: "The recording session lease is not held.",
        bundle: bundle
    ) }
    static var recordingAudioMissing: String { String(
        localized: "A recording file is missing.",
        bundle: bundle
    ) }
    static var recordingAudioFinalizationDelayed: String { String(
        localized: "Recording continues, but durable storage is temporarily delayed.",
        bundle: bundle
    ) }
    static var recordingAudioSafetyLimit: String { String(
        localized: "Recording stopped because the active segment reached its safety limit.",
        bundle: bundle
    ) }
    static var recordingAudioWriteQueueOverflow: String { String(
        localized: "Recording stopped because audio arrived faster than it could be stored.",
        bundle: bundle
    ) }
    static func recordingAudioStoppedWithDurableTime(reason: String, durableTime: String) -> String {
        String(
            localized: "\(reason) Audio through \(durableTime) is durable for every required source.",
            bundle: bundle
        )
    }

    static func recordingAudioRecoveryIncomplete(durableTime: String) -> String {
        String(
            localized: "The interrupted recording contains a damaged or missing interval. Audio through \(durableTime) is durable for every required source.",
            bundle: bundle
        )
    }

    static var language: String { String(localized: "Language", bundle: bundle) }
    static var join: String { String(localized: "Join", bundle: bundle) }
    static var expand: String { String(localized: "Expand", bundle: bundle) }
    static var collapse: String { String(localized: "Collapse", bundle: bundle) }
    static var back: String { String(localized: "Back", bundle: bundle) }
    static var backToApp: String { String(localized: "Back to App", bundle: bundle) }
    static var forward: String { String(localized: "Forward", bundle: bundle) }
    static var hideSidebar: String { String(localized: "Hide Sidebar", bundle: bundle) }
    static var showSidebar: String { String(localized: "Show Sidebar", bundle: bundle) }

    // MARK: - Sidebar

    static var createNewMeeting: String { String(localized: "Create New Meeting", bundle: bundle) }
    static var quickRecording: String { String(localized: "Quick Recording", bundle: bundle) }
    static func quickRecordingMeetingName(timestamp: String) -> String {
        String(
            format: String(localized: "Quick recording %@", bundle: bundle),
            locale: .current,
            timestamp
        )
    }

    static var home: String { String(localized: "Home", bundle: bundle) }
    static var meetings: String { String(localized: "Meetings", bundle: bundle) }
    static var recent: String { String(localized: "Recent", bundle: bundle) }
    static var projects: String { String(localized: "Projects", bundle: bundle) }
    static var list: String { String(localized: "List", bundle: bundle) }
    static var projectDetailDisplay: String { String(localized: "Project Detail Display", bundle: bundle) }
    static var previousMonth: String { String(localized: "Previous Month", bundle: bundle) }
    static var nextMonth: String { String(localized: "Next Month", bundle: bundle) }
    static var projectMeetingLimitReached: String { String(
        localized: "Only the newest 500 meetings are shown.",
        bundle: bundle
    ) }
    static var projectCalendarLimitReached: String { String(
        localized: "Only the newest 500 meetings in this month are shown.",
        bundle: bundle
    ) }

    static func otherMeetings(_ count: Int) -> String {
        String(format: String(localized: "%lld more", bundle: bundle), locale: .current, count)
    }

    static var sidebarOrganization: String { String(localized: "Organize Sidebar", bundle: bundle) }
    static var chronological: String { String(localized: "Chronological", bundle: bundle) }
    static var groupByProject: String { String(localized: "Group by Project", bundle: bundle) }
    static var pinned: String { String(localized: "Pinned", bundle: bundle) }
    static var projectOptions: String { String(localized: "Project Options", bundle: bundle) }
    static var pinProject: String { String(localized: "Pin Project", bundle: bundle) }
    static var unpinProject: String { String(localized: "Unpin Project", bundle: bundle) }
    static var openProject: String { String(localized: "Open Project", bundle: bundle) }
    static var editProject: String { String(localized: "Edit Project", bundle: bundle) }
    static var noMeetingsInProject: String { String(localized: "No meetings in this project", bundle: bundle) }
    static var projectManagement: String { String(localized: "Project Management", bundle: bundle) }
    static var organizations: String { String(localized: "Organizations", bundle: bundle) }
    static var department: String { String(localized: "Department", bundle: bundle) }
    static var people: String { String(localized: "People", bundle: bundle) }
    static var topics: String { String(localized: "Topics", bundle: bundle) }
    static var topicMeetingEvidence: String { String(localized: "Topic Meeting Evidence", bundle: bundle) }
    static func organizationAIPrompt(
        organizationID: UUID,
        projectID: UUID?,
        start: String,
        end: String
    ) -> String {
        String(
            format: String(localized: "Organization AI Prompt", bundle: bundle),
            locale: .current,
            organizationID.uuidString,
            projectID?.uuidString ?? String(localized: "Not specified", bundle: bundle),
            start,
            end
        )
    }

    static var topic: String { String(localized: "Topic", bundle: bundle) }
    static var customerIntelligence: String { String(localized: "Customer Intelligence", bundle: bundle) }

    static var customerIntelligenceInsights: String { String(localized: "Insights", bundle: bundle) }
    static var customerIntelligenceOverview: String { String(localized: "Overview", bundle: bundle) }
    static var customerIntelligenceAllCustomers: String { String(localized: "All Customers", bundle: bundle) }
    static var customerIntelligenceCustomer: String { String(localized: "Customer", bundle: bundle) }
    static var customerIntelligenceCustomerScope: String { String(localized: "Customer Scope", bundle: bundle) }
    static var customerIntelligenceSearchCustomers: String {
        String(localized: "Search customers", bundle: bundle)
    }

    static var customerIntelligenceOverviewAllDescription: String {
        String(localized: "Review activity and relationships across every customer.", bundle: bundle)
    }

    static var customerIntelligenceOverviewCustomerDescription: String {
        String(localized: "Review this customer's people, work, topics, and recent conversations.", bundle: bundle)
    }

    static var customerIntelligenceKeyPeople: String { String(localized: "Key People", bundle: bundle) }
    static var customerIntelligenceRecentProjects: String { String(localized: "Recent Projects", bundle: bundle) }
    static var customerIntelligenceRecentTopics: String { String(localized: "Recently Discussed Topics", bundle: bundle) }
    static var customerIntelligenceRecentMeetings: String { String(localized: "Recent Meetings", bundle: bundle) }
    static var customerIntelligenceNoRecentInteraction: String {
        String(localized: "No recent interaction", bundle: bundle)
    }

    static var customerIntelligenceOpenOrganizationHint: String {
        String(localized: "Selects this customer and opens its organization chart.", bundle: bundle)
    }

    static var customerIntelligencePersonDetails: String { String(localized: "Person Details", bundle: bundle) }
    static var customerIntelligencePersonCreationHelp: String {
        String(localized: "An initial organization is optional and can be changed later.", bundle: bundle)
    }

    static var customerIntelligenceNewPerson: String { String(localized: "New Person", bundle: bundle) }
    static var customerIntelligenceNewTopic: String { String(localized: "New Topic", bundle: bundle) }
    static var customerIntelligenceSaveFailed: String {
        String(localized: "The changes could not be saved.", bundle: bundle)
    }

    static var customerIntelligenceNoPeople: String { String(localized: "No People", bundle: bundle) }
    static var customerIntelligenceNoPeopleDescription: String {
        String(localized: "Create a person or change the customer scope.", bundle: bundle)
    }

    static var customerIntelligenceDeletePersonHelp: String {
        String(
            localized: "Deletes this person and detaches related references. This cannot be undone.",
            bundle: bundle
        )
    }

    static var customerIntelligenceNoTopics: String { String(localized: "No Topics", bundle: bundle) }
    static var customerIntelligenceNoTopicsDescription: String {
        String(localized: "Create a topic or use AI to organize recent conversations.", bundle: bundle)
    }

    static var customerIntelligenceEditTopic: String { String(localized: "Edit Topic", bundle: bundle) }
    static var customerIntelligenceLastDiscussed: String { String(localized: "Last Discussed", bundle: bundle) }
    static var customerIntelligenceDeleteTopicHelp: String {
        String(
            localized: "Deletes this topic and its references. Meetings and related records are preserved.",
            bundle: bundle
        )
    }

    static var customerIntelligenceViewOptions: String { String(localized: "View Options", bundle: bundle) }
    static var customerIntelligenceTableDensity: String { String(localized: "Table Density", bundle: bundle) }
    static var customerIntelligenceStandardDensity: String { String(localized: "Standard", bundle: bundle) }
    static var customerIntelligenceCompactDensity: String { String(localized: "Compact", bundle: bundle) }
    static var customerIntelligenceShowInspector: String { String(localized: "Show Inspector", bundle: bundle) }
    static var customerIntelligenceHideInspector: String { String(localized: "Hide Inspector", bundle: bundle) }
    static var customerIntelligenceSearchProjects: String { String(localized: "Search Projects", bundle: bundle) }
    static var customerIntelligenceProjectPath: String { String(localized: "Project Path", bundle: bundle) }
    static var customerIntelligenceRecentActivity: String { String(localized: "Recent Activity", bundle: bundle) }
    static var customerIntelligenceNoProjects: String { String(localized: "No Projects", bundle: bundle) }
    static var customerIntelligenceNoProjectsDescription: String {
        String(localized: "Create a Project or explicitly relate one to this customer.", bundle: bundle)
    }

    static var customerIntelligenceNoDescription: String { String(localized: "No description", bundle: bundle) }
    static var organizationDescription: String { String(localized: "Organization Description", bundle: bundle) }
    static var customerIntelligenceManageInProjects: String {
        String(localized: "Manage in Projects", bundle: bundle)
    }

    static var customerIntelligenceSelectProject: String {
        String(localized: "Select a Project", bundle: bundle)
    }

    static var customerIntelligenceProjectDetails: String { String(localized: "Project Details", bundle: bundle) }
    static var customerIntelligenceEditProject: String { String(localized: "Edit Project", bundle: bundle) }
    static var customerIntelligenceRevisionConflict: String {
        String(localized: "This record changed. Reload it before saving again.", bundle: bundle)
    }

    static var customerIntelligenceInsightSummary: String { String(localized: "Summary", bundle: bundle) }
    static var customerIntelligenceInsightContent: String { String(localized: "Insight", bundle: bundle) }
    static var customerIntelligenceUpdatedAt: String { String(localized: "Updated", bundle: bundle) }
    static var customerIntelligenceMarkNeedsReview: String {
        String(localized: "Mark as Needs Review", bundle: bundle)
    }

    static var customerIntelligenceNoInsights: String { String(localized: "No Insights", bundle: bundle) }
    static var customerIntelligenceNoInsightsDescription: String {
        String(localized: "Insights created by AI will appear here for review.", bundle: bundle)
    }

    static var projectTypeCustomer: String { String(localized: "Customer", bundle: bundle) }
    static var projectTypeInternal: String { String(localized: "Internal", bundle: bundle) }
    static var projectTypePersonal: String { String(localized: "Personal", bundle: bundle) }
    static var projectTypeUndefined: String { String(localized: "Undefined", bundle: bundle) }

    static func customerIntelligenceNeedsReviewCount(_ count: Int) -> String {
        String(
            format: String(localized: "%lld needs review", bundle: bundle),
            locale: .current,
            count
        )
    }

    static var customerIntelligenceEmail: String { String(localized: "Email Address", bundle: bundle) }
    static var customerIntelligenceLastInteraction: String {
        String(localized: "Last Interaction", bundle: bundle)
    }

    static var customerIntelligenceEditContact: String {
        String(localized: "Edit Contact", bundle: bundle)
    }

    static var customerIntelligenceEditOrganization: String {
        String(localized: "Edit Organization", bundle: bundle)
    }

    static var customerIntelligenceEditDepartment: String {
        String(localized: "Edit Department", bundle: bundle)
    }

    static var customerIntelligenceManageMemberships: String {
        String(localized: "Manage Memberships", bundle: bundle)
    }

    static var customerIntelligenceExistingMemberships: String {
        String(localized: "Existing Memberships", bundle: bundle)
    }

    static var customerIntelligenceAddMembership: String {
        String(localized: "Add Membership", bundle: bundle)
    }

    static var customerIntelligenceAddPerson: String {
        String(localized: "Add Person", bundle: bundle)
    }

    static var customerIntelligenceNoPeopleToAdd: String {
        String(localized: "There are no people available to add.", bundle: bundle)
    }

    static var customerIntelligenceManagePeopleHelp: String {
        String(localized: "Create people and edit their memberships from the People screen.", bundle: bundle)
    }

    static var customerIntelligenceEmailNotSet: String {
        String(localized: "Email address not set", bundle: bundle)
    }

    static var customerIntelligenceDeletePerson: String {
        String(localized: "Delete Person?", bundle: bundle)
    }

    static var customerIntelligenceNoMemberships: String {
        String(localized: "No organization memberships", bundle: bundle)
    }

    static var customerIntelligenceInvalidEmail: String {
        String(localized: "Enter a valid email address.", bundle: bundle)
    }

    static var customerIntelligenceSearchContacts: String {
        String(localized: "Search contacts", bundle: bundle)
    }

    static var customerIntelligenceSearchTopics: String {
        String(localized: "Search topics", bundle: bundle)
    }

    static var customerIntelligenceSearchInsights: String {
        String(localized: "Search insights", bundle: bundle)
    }

    static var customerIntelligenceSelectContact: String {
        String(localized: "Select a Contact", bundle: bundle)
    }

    static var customerIntelligenceSelectTopic: String {
        String(localized: "Select a Topic", bundle: bundle)
    }

    static var customerIntelligenceSelectInsight: String {
        String(localized: "Select an Insight", bundle: bundle)
    }

    static var customerIntelligenceCurrentState: String {
        String(localized: "Current State", bundle: bundle)
    }

    static var customerIntelligenceTopicTitle: String {
        String(localized: "Topic Title", bundle: bundle)
    }

    static var customerIntelligenceRelatedResources: String {
        String(localized: "Related Resources", bundle: bundle)
    }

    static var customerIntelligenceDangerZone: String {
        String(localized: "Danger Zone", bundle: bundle)
    }

    static var customerIntelligenceMerge: String { String(localized: "Merge", bundle: bundle) }
    static var customerIntelligenceMergeContactTitle: String {
        String(localized: "Merge with Existing Contact?", bundle: bundle)
    }

    static var customerIntelligenceAccept: String { String(localized: "Accept", bundle: bundle) }
    static var customerIntelligenceAccepted: String { String(localized: "Accepted", bundle: bundle) }
    static var customerIntelligenceNeedsReview: String { String(localized: "Needs Review", bundle: bundle) }

    static var customerIntelligenceAllStatuses: String {
        String(localized: "All Statuses", bundle: bundle)
    }

    static var customerIntelligenceNoVault: String {
        String(localized: "Open a Vault to view customer intelligence.", bundle: bundle)
    }

    static var customerIntelligenceUpdateError: String {
        String(localized: "Could Not Update Customer Intelligence", bundle: bundle)
    }

    static var customerIntelligencePeopleError: String {
        String(localized: "Could Not Update People", bundle: bundle)
    }

    static var customerIntelligenceProjectsError: String {
        String(localized: "Could Not Update Projects", bundle: bundle)
    }

    static var customerIntelligenceTopicsError: String {
        String(localized: "Could Not Update Topics", bundle: bundle)
    }

    static var customerIntelligenceInsightsError: String {
        String(localized: "Could Not Update Insights", bundle: bundle)
    }

    static var customerIntelligenceShowAllTopics: String {
        String(localized: "Show All Topics", bundle: bundle)
    }

    static func customerIntelligenceMergeContactMessage(_ name: String) -> String {
        String(
            format: String(localized: "This email belongs to “%@”. Merge this person into it?", bundle: bundle),
            locale: .current,
            name
        )
    }

    static var openOrganizationWorkspace: String {
        String(localized: "Open Customer Intelligence", bundle: bundle)
    }

    static var organizationCanvas: String { String(localized: "Organization hierarchy canvas", bundle: bundle) }
    static var unassignedPeople: String { String(localized: "Unassigned People", bundle: bundle) }
    static var unnamedPerson: String { String(localized: "Unnamed Person", bundle: bundle) }
    static var newOrganization: String { String(localized: "New Organization", bundle: bundle) }
    static var newDepartment: String { String(localized: "New Department", bundle: bundle) }
    static var parentDepartment: String { String(localized: "Parent Department", bundle: bundle) }
    static var move: String { String(localized: "Move", bundle: bundle) }
    static var person: String { String(localized: "Person", bundle: bundle) }
    static var role: String { String(localized: "Role", bundle: bundle) }
    static var deleteOrganization: String { String(localized: "Delete Organization?", bundle: bundle) }
    static func deleteOrganization(named name: String) -> String {
        String(
            format: String(localized: "Delete “%@”?", bundle: bundle),
            locale: .current,
            name
        )
    }

    static var deleteOrganizationAction: String { String(localized: "Delete Organization", bundle: bundle) }
    static var deleteOrganizationHelp: String { String(
        localized: "Deletes this organization and all departments below it. Memberships and related references are detached. This cannot be undone.",
        bundle: bundle
    ) }
    static var deleteTopic: String { String(localized: "Delete Topic?", bundle: bundle) }
    static var organizationDomains: String { String(localized: "Email Domains", bundle: bundle) }
    static var organizationDomain: String { String(localized: "Email Domain", bundle: bundle) }
    static var addOrganizationDomain: String { String(localized: "Add Email Domain", bundle: bundle) }
    static func organizationDomainAlreadyUsed(by organizationName: String) -> String {
        String(
            format: String(localized: "This email domain is already used by “%@”", bundle: bundle),
            locale: .current,
            organizationName
        )
    }

    static var addAsSharedOrganizationDomain: String {
        String(localized: "Add as Shared Domain", bundle: bundle)
    }

    static var mergeOrganizations: String { String(localized: "Merge Organizations", bundle: bundle) }

    static var automaticOrganizationMembership: String {
        String(localized: "Automatically link participants to organizations", bundle: bundle)
    }

    static var automaticOrganizationMembershipDescription: String {
        String(
            localized: "Organizations are still created for new domains when this is off. Shared domains never link participants automatically.",
            bundle: bundle
        )
    }

    static var organizationDomainHelp: String {
        String(
            localized: "If another organization uses this domain, you can add it as shared or review a complete merge.",
            bundle: bundle
        )
    }

    static var primary: String { String(localized: "Primary", bundle: bundle) }
    static var merge: String { String(localized: "Merge", bundle: bundle) }

    static func organizationMergeImpact(
        domainName: String,
        targetName: String,
        impact: OrganizationMergeImpact
    ) -> String {
        let domains = localizedCount(impact.domains, singular: "%lld domain", plural: "%lld domains")
        let memberships = localizedCount(impact.memberships, singular: "%lld membership", plural: "%lld memberships")
        let departments = localizedCount(
            impact.descendantOrganizations,
            singular: "%lld department",
            plural: "%lld departments"
        )
        let projects = localizedCount(impact.projects, singular: "%lld Project", plural: "%lld Projects")
        let topics = localizedCount(impact.topics, singular: "%lld Topic", plural: "%lld Topics")
        let insights = localizedCount(impact.insights, singular: "%lld insight", plural: "%lld insights")
        return String(
            format: String(
                // swiftlint:disable:next line_length
                localized: "The domain “%@” belongs to another organization. Adding it as shared keeps both organizations separate. The source contains %@, %@, %@, %@, %@, and %@. Merging into “%@” combines them and deletes the source organization. Matching relationships keep the target organization’s metadata.",
                bundle: bundle
            ),
            locale: .current,
            domainName,
            domains,
            memberships,
            departments,
            projects,
            topics,
            insights,
            targetName
        )
    }

    private static func localizedCount(
        _ count: Int,
        singular: String.LocalizationValue,
        plural: String.LocalizationValue
    ) -> String {
        String(
            format: String(localized: count == 1 ? singular : plural, bundle: bundle),
            locale: .current,
            count
        )
    }

    static var searchOrganizations: String { String(localized: "Search organizations", bundle: bundle) }
    static var noOrganizations: String { String(localized: "No Organizations", bundle: bundle) }
    static var noOrganizationsDescription: String {
        String(localized: "Calendar participants or direct edits can create the first organization.", bundle: bundle)
    }

    static var selectOrganization: String { String(localized: "Select an Organization", bundle: bundle) }
    static var allTopics: String { String(localized: "All Topics", bundle: bundle) }
    static var allProjects: String { String(localized: "All Projects", bundle: bundle) }
    static var organizationWorkspaceError: String {
        String(localized: "Could Not Update Organization Workspace", bundle: bundle)
    }

    static var organizationWorkspaceBusy: String {
        String(localized: "Dahlia data is busy. No changes were applied. Please retry.", bundle: bundle)
    }

    static var zoomIn: String { String(localized: "Zoom In", bundle: bundle) }
    static var zoomOut: String { String(localized: "Zoom Out", bundle: bundle) }
    static var fitToView: String { String(localized: "Fit to View", bundle: bundle) }
    static var organizeWithAI: String { String(localized: "Organize with AI", bundle: bundle) }
    static var analysisScope: String { String(localized: "Analysis Scope", bundle: bundle) }
    static var aiScopeDoesNotSend: String {
        String(localized: "This prepares an exact prompt in Chat. It does not send it automatically.", bundle: bundle)
    }

    static var prepareChat: String { String(localized: "Prepare Chat", bundle: bundle) }
    static var add: String { String(localized: "Add", bundle: bundle) }
    static var save: String { String(localized: "Save", bundle: bundle) }
    static var name: String { String(localized: "Name", bundle: bundle) }
    static var updated: String { String(localized: "Updated", bundle: bundle) }
    static var ascending: String { String(localized: "Ascending", bundle: bundle) }
    static var descending: String { String(localized: "Descending", bundle: bundle) }

    static func pastDays(_ count: Int) -> String {
        String(localized: "Past \(count) days", bundle: bundle)
    }

    static func topicDerivedSummary(meetings: Int, organizations: Int) -> String {
        String(localized: "\(meetings) meetings · \(organizations) departments", bundle: bundle)
    }

    static func contactDeletionImpact(_ impact: ProvisionalContactDeletionImpact) -> String {
        String(
            localized: "\(impact.memberships) memberships, \(impact.projects) Projects, \(impact.insights) insights, and \(impact.topics) Topics will be detached.",
            bundle: bundle
        )
    }

    static func organizationDeletionImpact(_ impact: OrganizationDeletionImpact) -> String {
        String(
            localized: "This deletes \(impact.organizationCount) organization nodes and detaches \(impact.memberships) memberships, \(impact.projects) Projects, \(impact.topics) Topics, and \(impact.insights) insights.",
            bundle: bundle
        )
    }

    static func topicDeletionImpact(_ impact: TopicDeletionImpact) -> String {
        String(
            localized: "This removes \(impact.meetings) Meeting references and \(impact.relatedResources) related resources. The source records are preserved.",
            bundle: bundle
        )
    }

    static var instructions: String { String(localized: "Instructions", bundle: bundle) }
    static var context: String { String(localized: "Context", bundle: bundle) }
    static var actionItems: String { String(localized: "Action Items", bundle: bundle) }
    static var me: String { String(localized: "Me", bundle: bundle) }
    static var ask: String { String(localized: "Ask", bundle: bundle) }
    static var newProject: String { String(localized: "New Project", bundle: bundle) }
    static var createProject: String { String(localized: "Create Project", bundle: bundle) }
    static var newSubproject: String { String(localized: "New Subproject", bundle: bundle) }
    static var newTopLevelProject: String { String(localized: "New Project at Vault Top", bundle: bundle) }

    static var projectCreationFailedDescription: String {
        String(localized: "The project could not be created.", bundle: bundle)
    }

    static var newMeeting: String { String(localized: "New meeting", bundle: bundle) }

    static func chatMeetingDraft(_ name: String) -> String {
        String(localized: "Meeting draft: \(name)", bundle: bundle)
    }

    static func chatContextChanged(_ name: String) -> String {
        String(localized: "Context changed to \(name)", bundle: bundle)
    }

    static var chatSelectedMeetingUnavailable: String {
        String(localized: "The selected meeting is no longer available.", bundle: bundle)
    }

    static var chatSelectedProjectUnavailable: String { String(
        localized: "The selected project is no longer available.",
        bundle: bundle
    ) }

    static var projectName: String { String(localized: "Project Name", bundle: bundle) }
    static var projectIcon: String { String(localized: "Project Icon", bundle: bundle) }
    static var projectThemeColor: String { String(localized: "Theme Color", bundle: bundle) }
    static var projectColorNeutral: String { String(localized: "Neutral", bundle: bundle) }
    static var projectColorRed: String { String(localized: "Red", bundle: bundle) }
    static var projectColorOrange: String { String(localized: "Orange", bundle: bundle) }
    static var projectColorYellow: String { String(localized: "Yellow", bundle: bundle) }
    static var projectColorGreen: String { String(localized: "Green", bundle: bundle) }
    static var projectColorBlue: String { String(localized: "Blue", bundle: bundle) }
    static var projectColorPurple: String { String(localized: "Purple", bundle: bundle) }
    static var projectColorPink: String { String(localized: "Pink", bundle: bundle) }
    static var projectIconFolder: String { String(localized: "Folder", bundle: bundle) }
    static var projectIconFinance: String { String(localized: "Finance", bundle: bundle) }
    static var projectIconBook: String { String(localized: "Book", bundle: bundle) }
    static var projectIconEducation: String { String(localized: "Education", bundle: bundle) }
    static var projectIconWriting: String { String(localized: "Writing", bundle: bundle) }
    static var projectIconCode: String { String(localized: "Code", bundle: bundle) }
    static var projectIconTerminal: String { String(localized: "Terminal", bundle: bundle) }
    static var projectIconMusic: String { String(localized: "Music", bundle: bundle) }
    static var projectIconFilm: String { String(localized: "Film", bundle: bundle) }
    static var projectIconArt: String { String(localized: "Art", bundle: bundle) }
    static var projectIconHealth: String { String(localized: "Health", bundle: bundle) }
    static var projectIconPuzzle: String { String(localized: "Puzzle", bundle: bundle) }
    static var projectIconNature: String { String(localized: "Nature", bundle: bundle) }
    static var projectIconWork: String { String(localized: "Work", bundle: bundle) }
    static var projectIconAnalytics: String { String(localized: "Analytics", bundle: bundle) }
    static var projectIconAward: String { String(localized: "Award", bundle: bundle) }
    static var projectIconFitness: String { String(localized: "Fitness", bundle: bundle) }
    static var projectIconNotes: String { String(localized: "Notes", bundle: bundle) }
    static var projectIconBalance: String { String(localized: "Balance", bundle: bundle) }
    static var projectIconGlobal: String { String(localized: "Global", bundle: bundle) }
    static var projectIconTravel: String { String(localized: "Travel", bundle: bundle) }
    static var projectIconTools: String { String(localized: "Tools", bundle: bundle) }
    static var projectIconAnimals: String { String(localized: "Animals", bundle: bundle) }
    static var projectIconScience: String { String(localized: "Science", bundle: bundle) }
    static var projectIconIdeas: String { String(localized: "Ideas", bundle: bundle) }
    static var projectIconFavorite: String { String(localized: "Favorite", bundle: bundle) }
    static var parentProject: String { String(localized: "Parent Project", bundle: bundle) }
    static var vaultRoot: String { String(localized: "Vault Root", bundle: bundle) }
    static var projectType: String { String(localized: "Project Type", bundle: bundle) }
    static var projectHierarchyAndType: String { String(localized: "Hierarchy and Type", bundle: bundle) }
    static var moveProject: String { String(localized: "Move Project", bundle: bundle) }
    static var updateProjectType: String { String(localized: "Update Project Type", bundle: bundle) }
    static var projectHierarchyChangeHelp: String { String(
        localized: "Moving or changing a root type also updates every descendant's path or inherited type.",
        bundle: bundle
    ) }
    static var subprojectTypeInheritanceHelp: String { String(
        localized: "This subproject inherits its Project Type from the root Project.",
        bundle: bundle
    ) }

    static func inheritedFromProject(_ name: String) -> String {
        String(localized: "Inherited from \(name)", bundle: bundle)
    }

    static func projectTypeName(_ type: ProjectType) -> String {
        switch type {
        case .customer: String(localized: "Customer", bundle: bundle)
        case .internal: String(localized: "Internal", bundle: bundle)
        case .personal: String(localized: "Personal", bundle: bundle)
        case .undefined: String(localized: "Undefined", bundle: bundle)
        }
    }

    static var renameProject: String { String(localized: "Rename Project", bundle: bundle) }
    static var projectNameHelp: String { String(
        localized: "Renaming updates the logical Project path and tracked Summary outputs. Unrelated directories and files are not moved.",
        bundle: bundle
    ) }
    static var location: String { String(localized: "Location", bundle: bundle) }
    static var openInFinder: String { String(localized: "Open in Finder", bundle: bundle) }
    static var openInObsidian: String { String(localized: "Open in Obsidian", bundle: bundle) }
    static var openInBrowser: String { String(localized: "Open in Browser", bundle: bundle) }
    static var openProjects: String { String(localized: "Open Projects", bundle: bundle) }
    static var title: String { String(localized: "Title", bundle: bundle) }
    static var all: String { String(localized: "All", bundle: bundle) }
    static var filter: String { String(localized: "Filter", bundle: bundle) }
    static var tags: String { String(localized: "Tags", bundle: bundle) }
    static var completed: String { String(localized: "Completed", bundle: bundle) }
    static var waiting: String { String(localized: "Waiting", bundle: bundle) }
    static var skipped: String { String(localized: "Skipped", bundle: bundle) }
    static var today: String { String(localized: "Today", bundle: bundle) }
    static var tomorrow: String { String(localized: "Tomorrow", bundle: bundle) }
    static var inProgress: String { String(localized: "In Progress", bundle: bundle) }
    static var noMeetingsYet: String { String(localized: "No meetings yet", bundle: bundle) }
    static var searchMeetings: String { String(localized: "Search meetings...", bundle: bundle) }
    static var searchMeetingsAndProjects: String { String(localized: "Search meetings, screenshots, and projects", bundle: bundle) }
    static var screenshotSearchResults: String { String(localized: "Screenshots", bundle: bundle) }
    static var detectedText: String { String(localized: "Detected Text", bundle: bundle) }
    static var imageDescription: String { String(localized: "Image Description", bundle: bundle) }
    static var noTextDetected: String { String(localized: "No text was detected.", bundle: bundle) }
    static var imageAnalysisFailed: String { String(localized: "Image analysis failed.", bundle: bundle) }
    static var analyzingImage: String { String(localized: "Analyzing image...", bundle: bundle) }
    static var searchMode: String { String(localized: "Search mode", bundle: bundle) }
    static var searchModeSimple: String { String(localized: "Search mode Simple", bundle: bundle) }
    static var searchModeAdvanced: String { String(localized: "Search mode Advanced", bundle: bundle) }
    static var searchModeNeural: String { String(localized: "Search mode Neural", bundle: bundle) }
    static var closeSearch: String { String(localized: "Close search", bundle: bundle) }
    static var removeSearchFilter: String { String(localized: "Remove search filter", bundle: bundle) }
    static var searchUnavailable: String { String(localized: "Search unavailable", bundle: bundle) }
    static var searchRequiresVault: String { String(localized: "Select a Vault to search.", bundle: bundle) }
    static var recentMeetings: String { String(localized: "Recent Meetings", bundle: bundle) }
    static var recentProjects: String { String(localized: "Recent Projects", bundle: bundle) }
    static var searchingMeetings: String { String(localized: "Searching…", bundle: bundle) }
    static var noMeetingsMatchSearch: String { String(localized: "No meetings match your search", bundle: bundle) }
    static var adjustMeetingSearch: String { String(
        localized: "Try changing the keywords or filters.",
        bundle: bundle
    ) }
    static func searchInputLimitReached(_ count: Int) -> String {
        String(localized: "Search is limited to \(count) characters. Extra text was not entered.", bundle: bundle)
    }

    static var clearAllSearchConditions: String { String(localized: "Clear All", bundle: bundle) }
    static var selectedMeetingOutsideResults: String { String(localized: "Selected (Outside Results)", bundle: bundle) }
    static var period: String { String(localized: "Period", bundle: bundle) }
    static var tag: String { String(localized: "Tag", bundle: bundle) }
    static var projectsAnyMatch: String { String(localized: "Projects (match any)", bundle: bundle) }
    static var tagsAnyMatch: String { String(localized: "Tags (match any)", bundle: bundle) }
    static var includesSubprojects: String { String(localized: "Includes subprojects", bundle: bundle) }
    static var noTagsYet: String { String(localized: "No tags yet", bundle: bundle) }
    static var noMatchingTags: String { String(localized: "No matching tags", bundle: bundle) }
    static var loadingTags: String { String(localized: "Loading Tags…", bundle: bundle) }
    static var pastSevenDays: String { String(localized: "Past 7 days", bundle: bundle) }
    static var pastThirtyDays: String { String(localized: "Past 30 days", bundle: bundle) }
    static var customDateRange: String { String(localized: "Custom Range", bundle: bundle) }
    static var startDate: String { String(localized: "Start Date", bundle: bundle) }
    static var endDate: String { String(localized: "End Date", bundle: bundle) }
    static var invalidDateRange: String { String(localized: "Start date must be on or before the end date.", bundle: bundle) }
    static var unknownProject: String { String(localized: "Unknown Project", bundle: bundle) }
    static var unknownTag: String { String(localized: "Unknown Tag", bundle: bundle) }
    static var unknownProjectFilterHelp: String { String(
        localized: "Unknown project. Select the filter and press Delete to remove it.",
        bundle: bundle
    ) }
    static var unknownTagFilterHelp: String { String(
        localized: "Unknown tag. Select the filter and press Delete to remove it.",
        bundle: bundle
    ) }
    static var unknownProjectFilterAccessibilityLabel: String {
        String(localized: "Unknown project filter", bundle: bundle)
    }

    static var unknownTagFilterAccessibilityLabel: String {
        String(localized: "Unknown tag filter", bundle: bundle)
    }

    static var periodFilter: String { String(localized: "Period filter", bundle: bundle) }
    static var projectFilter: String { String(localized: "Project filter", bundle: bundle) }
    static var tagFilter: String { String(localized: "Tag filter", bundle: bundle) }
    static var descriptionTitle: String { String(localized: "Description", bundle: bundle) }
    static var descriptionMatch: String { String(localized: "Description:", bundle: bundle) }
    static var summaryMatch: String { String(localized: "Summary:", bundle: bundle) }
    static var calendarMatch: String { String(localized: "Event:", bundle: bundle) }
    static var tagMatch: String { String(localized: "Tag:", bundle: bundle) }
    static var projectMatch: String { String(localized: "Project:", bundle: bundle) }
    static var selectedMeeting: String { String(localized: "Selected Meeting", bundle: bundle) }
    static var loadingMeetings: String { String(localized: "Loading Meetings…", bundle: bundle) }
    static var loadingMoreMeetings: String { String(localized: "Loading More…", bundle: bundle) }
    static var retryLoadingMeetings: String { String(localized: "Retry Loading", bundle: bundle) }
    static var meetingListLoadFailed: String { String(localized: "Could Not Load Meetings", bundle: bundle) }
    static var searchForOlderMeetings: String { String(localized: "Search to find older meetings.", bundle: bundle) }
    static var refineMeetingSearch: String { String(localized: "Refine your search to find older meetings.", bundle: bundle) }
    static var createFirstMeetingDescription: String { String(
        localized: "Create a meeting to start building your history.",
        bundle: bundle
    ) }

    static func projectFilterHelp(_ projectName: String) -> String {
        String(format: String(localized: "Project: %@ (includes subprojects)", bundle: bundle), projectName)
    }

    static func projectFilterAccessibilityLabel(_ projectName: String) -> String {
        String(
            format: String(localized: "Project filter, %@, includes subprojects", bundle: bundle),
            projectName
        )
    }

    static func tagFilterHelp(_ tagName: String) -> String {
        String(format: String(localized: "Tag: %@", bundle: bundle), tagName)
    }

    static func tagFilterAccessibilityLabel(_ tagName: String) -> String {
        String(format: String(localized: "Tag filter, %@", bundle: bundle), tagName)
    }

    static func periodFilterAccessibilityLabel(_ period: String) -> String {
        String(format: String(localized: "Period filter, %@", bundle: bundle), period)
    }

    static func dateRange(_ startDate: String, _ endDate: String) -> String {
        String(format: String(localized: "%@ – %@", bundle: bundle), startDate, endDate)
    }

    static func dateOnOrAfter(_ date: String) -> String {
        String(format: String(localized: "On or after %@", bundle: bundle), date)
    }

    static func dateBefore(_ date: String) -> String {
        String(format: String(localized: "Before %@", bundle: bundle), date)
    }

    static var searchProjects: String { String(localized: "Search projects...", bundle: bundle) }
    static var moveToProject: String { String(localized: "Move to Project", bundle: bundle) }
    static var noMeetingSelected: String { String(localized: "No meeting selected", bundle: bundle) }
    static var noProjectsYet: String { String(localized: "No projects yet", bundle: bundle) }
    static var noProjectsMatchFilter: String { String(localized: "No projects match the current filter.", bundle: bundle) }
    static var loadingProjects: String { String(localized: "Loading Projects…", bundle: bundle) }
    static var projectCatalogLoadFailed: String { String(localized: "Could Not Load Projects", bundle: bundle) }
    static var projectCatalogLoadFailedDescription: String { String(
        localized: "Try loading the project list again.",
        bundle: bundle
    ) }
    static var createFirstProjectDescription: String { String(
        localized: "Create a project to organize meetings and summaries.",
        bundle: bundle
    ) }
    static var clearSearch: String { String(localized: "Clear Search", bundle: bundle) }
    static var noInstructionsYet: String { String(localized: "No instructions yet", bundle: bundle) }
    static func meetingCount(_ count: Int) -> String { String(localized: "\(count) meetings", bundle: bundle) }
    static func compactMeetingCount(_ count: Int) -> String { String(localized: "\(count)", bundle: bundle) }

    static func includedSubprojectCount(_ count: Int) -> String {
        String(localized: "\(count) subprojects included", bundle: bundle)
    }

    static var recordingNow: String { String(localized: "Recording now", bundle: bundle) }
    static var transcribingNow: String { String(localized: "Transcribing now", bundle: bundle) }
    static var returnToRecordingMeeting: String { String(localized: "Return to recording meeting", bundle: bundle) }
    static var returnToTranscribingMeeting: String { String(localized: "Return to transcribing meeting", bundle: bundle) }
    static var yesterday: String { String(localized: "Yesterday", bundle: bundle) }
    static func deleteCount(_ count: Int) -> String { String(localized: "Delete \(count) items", bundle: bundle) }
    static func deleteMeetingConfirmation(_ name: String) -> String {
        String(format: String(localized: "Delete %@?", bundle: bundle), name)
    }

    static func deleteMeetingsConfirmation(_ count: Int) -> String {
        String(localized: "Delete \(count) meetings?", bundle: bundle)
    }

    static var deleteMeetingWarning: String { String(
        localized: "Delete this meeting and all its data permanently, including its transcript and Dahlia-managed audio. This cannot be undone.",
        bundle: bundle
    ) }

    static func deleteMeetingsWarning(_ count: Int) -> String {
        String(
            localized: "Delete \(count) meetings and all their data permanently, including transcripts and Dahlia-managed audio. This cannot be undone.",
            bundle: bundle
        )
    }

    static func selectedCount(_ count: Int) -> String { String(localized: "\(count) selected", bundle: bundle) }

    // MARK: - Meeting Metadata

    static var addTag: String { String(localized: "Add tag", bundle: bundle) }
    static var searchOrCreateTag: String { String(localized: "Search or create tag...", bundle: bundle) }
    static var searchOrCreateProject: String { String(localized: "Search or create project...", bundle: bundle) }
    static var addInstruction: String { String(localized: "Add Instruction", bundle: bundle) }
    static var addInstructionDescription: String { String(localized: "Create your first instruction to customize summary output.", bundle: bundle) }
    static var selectInstruction: String { String(localized: "Select Instruction", bundle: bundle) }
    static var selectInstructionDescription: String { String(localized: "Select an instruction to edit.", bundle: bundle) }
    static var useForSummary: String { String(localized: "Use for Summary", bundle: bundle) }
    static var useAutoInstructions: String { String(localized: "Use Auto", bundle: bundle) }
    static var summaryInstructionSelected: String { String(localized: "This instruction is currently used for summary generation.", bundle: bundle) }
    static var summaryInstructionNotSelected: String { String(
        localized: "This instruction is not currently used for summary generation.",
        bundle: bundle
    ) }
    static var changesSaveAutomatically: String { String(localized: "Changes save automatically.", bundle: bundle) }
    static var instructionTitleRequired: String { String(localized: "Enter a title to save this instruction.", bundle: bundle) }
    static var deleteInstructionWarning: String { String(
        localized: "This instruction will be permanently deleted. This cannot be undone.",
        bundle: bundle
    ) }

    static func deleteInstructionConfirmation(_ name: String) -> String {
        String(format: String(localized: "Delete instruction \"%@\"?", bundle: bundle), name)
    }

    static var instructionsEmptyContent: String { String(localized: "No content yet", bundle: bundle) }
    static var noResultsFound: String { String(localized: "No results found", bundle: bundle) }
    static var noProject: String { String(localized: "No project", bundle: bundle) }
    static var summaryDestinations: String { String(localized: "Summary Destinations", bundle: bundle) }
    static var summaryDestinationsDescription: String { String(
        localized: "The logical Project path determines this destination. The folder is created when a Summary is exported.",
        bundle: bundle
    ) }
    static var localSummaryFolder: String { String(localized: "Local Summary Folder", bundle: bundle) }
    static var invalidSummaryOutputDestination: String { String(
        localized: "The Summary output destination must resolve inside the Vault without symlink or file path components.",
        bundle: bundle
    ) }
    static var summaryOutputFolderNotCreated: String { String(
        localized: "The Summary output folder has not been created yet.",
        bundle: bundle
    ) }
    static var projectDescription: String { String(localized: "Project Description", bundle: bundle) }
    static var projectDescriptionHelp: String { String(
        localized: "The description is provided as context when generating summaries. For example, you can include project members.",
        bundle: bundle
    ) }
    static var projectDescriptionPlaceholder: String { String(localized: "Describe this project...", bundle: bundle) }
    static var projectDescriptionSaveFailed: String { String(localized: "Could not save the project description.", bundle: bundle) }
    static var saving: String { String(localized: "Saving…", bundle: bundle) }
    static var saved: String { String(localized: "Saved", bundle: bundle) }
    static var dangerZone: String { String(localized: "Danger Zone", bundle: bundle) }
    static var projectOverview: String { String(localized: "Project Overview", bundle: bundle) }
    static var includedSubprojects: String { String(localized: "Included Subprojects", bundle: bundle) }
    static var meetingsInThisProject: String { String(localized: "Meetings in This Project", bundle: bundle) }
    static var meetingsInHierarchy: String { String(localized: "Meetings in Hierarchy", bundle: bundle) }
    static var deleteProject: String { String(localized: "Delete Project", bundle: bundle) }
    static var deleteProjectHelp: String { String(
        localized: "Deletes this Project and its subprojects from Dahlia. Export directories and unrelated files are kept.",
        bundle: bundle
    ) }

    static func deleteProjectConfirmation(_ name: String) -> String {
        String(localized: "Delete \(name)?", bundle: bundle)
    }

    static func projectDeletionSummary(projectCount: Int, meetingCount: Int) -> String {
        String(localized: "This affects \(projectCount) projects and \(meetingCount) meetings.", bundle: bundle)
    }

    static var projectDirectoriesAreKept: String { String(
        localized: "Project directories and unrelated files will be kept.",
        bundle: bundle
    ) }
    static var deleteExportedSummaries: String {
        String(localized: "Move exported Summary files to the Trash", bundle: bundle)
    }

    static var deleteExportedSummariesHelp: String { String(
        localized: "Off by default. Project directories and unrelated files are always kept.",
        bundle: bundle
    ) }

    static func projectMeetingsWillBeDeleted(_ count: Int) -> String {
        String(
            localized: "\(count) meetings and their transcripts will be permanently deleted. This cannot be undone.",
            bundle: bundle
        )
    }

    static func projectMeetingsWillBeMoved(count: Int, destination: String) -> String {
        String(localized: "\(count) meetings will be moved to \(destination) before deletion.", bundle: bundle)
    }

    static var deletingProjects: String { String(localized: "Deleting Projects…", bundle: bundle) }

    static var meetingHandling: String { String(localized: "Meeting History", bundle: bundle) }
    static var moveMeetingsBeforeDeletingProject: String { String(
        localized: "Move meetings to another project",
        bundle: bundle
    ) }
    static var deleteMeetingsWithProject: String { String(
        localized: "Delete meetings and their transcripts",
        bundle: bundle
    ) }
    static var moveMeetingsTo: String { String(localized: "Move Meetings To", bundle: bundle) }
    static var noProjectMoveDestination: String { String(
        localized: "There are no other available projects to move meetings to.",
        bundle: bundle
    ) }
    static var moveAndDeleteProject: String { String(localized: "Move Meetings and Delete Project", bundle: bundle) }
    static var deleteProjectAndMeetings: String { String(localized: "Delete Project and Meetings", bundle: bundle) }
    static var projectOperationFailed: String { String(localized: "Could Not Update Project", bundle: bundle) }
    static var projectOperationFailedDescription: String {
        String(localized: "The project operation could not be completed.", bundle: bundle)
    }

    static var projectNotFound: String { String(localized: "The project could not be found.", bundle: bundle) }
    static var invalidProjectName: String { String(
        localized: "Enter a valid project name without '/', ':', control characters, or a leading '.' or '_'.",
        bundle: bundle
    ) }
    static var projectNameTooLong: String { String(localized: "The project name is too long.", bundle: bundle) }

    static func projectAlreadyExists(_ name: String) -> String {
        String(localized: "A project named \(name) already exists in this location.", bundle: bundle)
    }

    static var subprojectTypeInheritanceError: String { String(
        localized: "Subprojects inherit their Project Type from the root Project.",
        bundle: bundle
    ) }
    static func staleProjectRevision(_ revision: Int) -> String {
        String(localized: "The Project changed before this update. Its current revision is \(revision).", bundle: bundle)
    }

    static var projectCycleError: String { String(
        localized: "A Project cannot be moved inside itself or one of its descendants.",
        bundle: bundle
    ) }
    static var projectHierarchyTooDeep: String { String(
        localized: "Projects support one level of subprojects. Choose a root Project as the parent.",
        bundle: bundle
    ) }
    static var projectVaultBusy: String { String(
        localized: "Another Project operation is already running for this Vault.",
        bundle: bundle
    ) }
    static var summaryTrashLocationUnavailable: String { String(
        localized: "The Summary output could not be moved to a recoverable Trash location.",
        bundle: bundle
    ) }
    static var invalidProjectMoveDestination: String { String(
        localized: "Choose an available project outside the hierarchy being deleted.",
        bundle: bundle
    ) }

    static func summaryFileAlreadyExists(_ name: String) -> String {
        String(localized: "A summary file named \(name) already exists in the destination.", bundle: bundle)
    }

    static func summaryFileShared(_ name: String) -> String {
        String(localized: "The summary file \(name) is linked to multiple meetings and cannot be moved safely.", bundle: bundle)
    }

    static func projectRollbackFailed(operation: String, rollback: String) -> String {
        String(
            localized: "The project operation failed (\(operation)), and Dahlia could not restore the Summary output (\(rollback)).",
            bundle: bundle
        )
    }

    static var selectProjectToManageDescription: String { String(
        localized: "Select a project to manage summary destinations and instructions.",
        bundle: bundle
    ) }
    static var projectManagementNoVaultDescription: String { String(
        localized: "Open a vault before managing project settings.",
        bundle: bundle
    ) }

    // MARK: - Control Panel

    static var audioSource: String { String(localized: "Audio source", bundle: bundle) }
    static var preparingSpeechRecognition: String { String(localized: "Preparing speech recognition...", bundle: bundle) }
    static var transcription: String { String(localized: "Transcription", bundle: bundle) }
    static func segmentCount(_ count: Int) -> String { String(localized: "\(count) segments", bundle: bundle) }
    static var stop: String { String(localized: "Stop", bundle: bundle) }
    static var startRecording: String { String(localized: "Start Recording", bundle: bundle) }
    static var stopRecording: String { String(localized: "Stop Recording", bundle: bundle) }
    static var recordingSessionAlreadyActive: String { String(localized: "A recording session is already active.", bundle: bundle) }
    static var recordingSessionNotActive: String { String(localized: "No recording session is active.", bundle: bundle) }
    static var stopTranscribing: String { String(localized: "Stop transcribing", bundle: bundle) }
    static var pause: String { String(localized: "Pause", bundle: bundle) }
    static var resume: String { String(localized: "Resume", bundle: bundle) }
    static var record: String { String(localized: "Record", bundle: bundle) }
    static var export: String { String(localized: "Export", bundle: bundle) }
    static var screen: String { String(localized: "Screen", bundle: bundle) }
    static var source: String { String(localized: "Source", bundle: bundle) }
    static var notSelected: String { String(localized: "Not Selected", bundle: bundle) }
    static var entireDesktop: String { String(localized: "Entire Desktop", bundle: bundle) }
    static var screenshotDisplayUnavailable: String { String(localized: "Display not found", bundle: bundle) }
    static var screenshotEncodingFailed: String { String(localized: "Screenshot encoding failed", bundle: bundle) }
    static var screenshotSourceUnavailable: String { String(localized: "Screenshot source is not selected or is unavailable", bundle: bundle) }
    static func screenshotCaptureFailed(_ reason: String) -> String { String(localized: "Screenshot capture failed: \(reason)", bundle: bundle) }
    static func screenshotDownloadFailed(_ reason: String) -> String { String(localized: "Screenshot download failed: \(reason)", bundle: bundle) }
    static var automaticScreenshots: String { String(localized: "Automatic Screenshots", bundle: bundle) }
    static var automaticScreenshotsDescription: String { String(
        localized: "Capture the screen during recording and save a new image when the display changes significantly.",
        bundle: bundle
    ) }
    static var enableAutomaticScreenshotsToConfigure: String { String(
        localized: "Turn on automatic screenshots to choose the interval and change threshold.",
        bundle: bundle
    ) }
    static var automaticScreenshotsToggleDescription: String { String(
        localized: "Automatically add screenshots while recording.",
        bundle: bundle
    ) }
    static var screenshotInterval: String { String(localized: "Screenshot Interval", bundle: bundle) }
    static var screenshotIntervalDescription: String { String(
        localized: "Choose how often Dahlia checks the screen for meaningful changes.",
        bundle: bundle
    ) }
    static var screenshotChangeThreshold: String { String(localized: "Screenshot Change Threshold", bundle: bundle) }
    static var screenshotChangeThresholdDescription: String { String(
        localized: "Save a new screenshot when at least this much of the screen changes.",
        bundle: bundle
    ) }
    static var sharedContent: String { String(localized: "Shared Content", bundle: bundle) }
    static var detectScreenshotChangesInSharedContentOnly: String { String(
        localized: "Detect Changes in Shared Content Only",
        bundle: bundle
    ) }
    static var sharedContentChangeDetectionDescription: String { String(
        localized: "Ignore changes outside detected slides or shared screens.",
        bundle: bundle
    ) }
    static var saveSharedContentOnly: String { String(localized: "Save Shared Content Only", bundle: bundle) }
    static var saveSharedContentOnlyDescription: String { String(
        localized: "Crop screenshots to detected slides or shared screens.",
        bundle: bundle
    ) }
    static var sharedContentDetectionFallbackDescription: String { String(
        localized: "When shared content cannot be detected reliably, Dahlia uses the entire selected screen or window.",
        bundle: bundle
    ) }
    static func seconds(_ count: Int) -> String { String(localized: "\(count) seconds", bundle: bundle) }
    static func percent(_ count: Int) -> String { String(localized: "\(count)%", bundle: bundle) }
    static var showLiveSubtitles: String { String(localized: "Show Live Subtitles", bundle: bundle) }
    static var hideLiveSubtitles: String { String(localized: "Hide Live Subtitles", bundle: bundle) }
    static var liveSubtitles: String { String(localized: "Live Subtitles", bundle: bundle) }
    static var subtitles: String { String(localized: "Subtitles", bundle: bundle) }
    static var liveSubtitlesOnStatus: String { String(localized: "Live subtitles on", bundle: bundle) }
    static var liveSubtitlesOffStatus: String { String(localized: "Live subtitles off", bundle: bundle) }
    static var liveSubtitleOverlay: String { String(localized: "Live Subtitle Overlay", bundle: bundle) }
    static var liveSubtitleOverlayToggleDescription: String { String(
        localized: "Show live subtitles when recording starts.",
        bundle: bundle
    ) }
    static var liveSubtitleOverlayDescription: String {
        [
            String(localized: "Live subtitles are available with both real-time and batch transcription.", bundle: bundle),
            String(localized: "In batch mode, subtitles are temporary and the final transcript is created after recording stops.", bundle: bundle),
        ].joined(separator: " ")
    }

    static var enableLiveSubtitlesToConfigure: String { String(
        localized: "Turn on live subtitles to choose their source and line count.",
        bundle: bundle
    ) }

    static var includeMicrophone: String { String(localized: "Include Microphone", bundle: bundle) }
    static var liveSubtitleMicrophoneDescription: String { String(
        localized: "Include microphone input in live subtitles. This does not change recorded audio or the final transcript.",
        bundle: bundle
    ) }
    static var liveSubtitleOverlaySegmentCount: String { String(localized: "Overlay Segment Count", bundle: bundle) }
    static var liveSubtitleOverlaySegmentCountDescription: String { String(
        localized: "Choose how many recent transcript segments are visible at once in the live subtitle overlay.",
        bundle: bundle
    ) }
    static var liveSubtitleConversionFailed: String { String(
        localized: "Live subtitles stopped because the audio format could not be converted.",
        bundle: bundle
    ) }

    // MARK: - Detail Tabs

    static var summary: String { String(localized: "Summary", bundle: bundle) }
    static var notes: String { String(localized: "Notes", bundle: bundle) }
    static var notesPlaceholder: String { String(localized: "NotesPlaceholder", bundle: bundle) }
    static var screenshots: String { String(localized: "Screenshots", bundle: bundle) }
    static var transcript: String { String(localized: "Transcript", bundle: bundle) }
    static var transcriptEmpty: String { String(localized: "No transcript yet.", bundle: bundle) }
    static func transcriptLoadFailed(_ reason: String) -> String {
        String(localized: "Some transcript could not be loaded: \(reason)", bundle: bundle)
    }

    static var newerTranscriptAvailable: String { String(localized: "New transcript available", bundle: bundle) }
    static var batchTranscriptionAwaitingConfirmation: String { String(
        localized: "Audio is ready. Confirm the transcription language to start.",
        bundle: bundle
    ) }
    static var reviewBatchTranscription: String { String(localized: "Review and Start", bundle: bundle) }
    static var batchTranscriptionQueued: String { String(localized: "Waiting to transcribe the recording…", bundle: bundle) }
    static var batchTranscriptionRunning: String { String(localized: "Creating a high-accuracy transcript…", bundle: bundle) }
    static var batchTranscriptionInterrupted: String { String(
        localized: "Transcription was interrupted. The recording is safe and ready to resume.",
        bundle: bundle
    ) }
    static var batchTranscriptionRecoveryFailedTitle: String {
        String(localized: "Could not recover interrupted transcriptions", bundle: bundle)
    }

    static var resumeBatchTranscription: String { String(localized: "Resume Transcription", bundle: bundle) }
    static func batchTranscriptionFileProgress(completed: Int, total: Int) -> String {
        String(localized: "Files completed: \(completed) of \(total)", bundle: bundle)
    }

    static func batchTranscriptionFailed(_ reason: String) -> String {
        String(localized: "Batch transcription failed: \(reason)", bundle: bundle)
    }

    static var retryBatchTranscription: String { String(localized: "Retry Batch Transcription", bundle: bundle) }
    static var keepCurrentTranscript: String { String(localized: "Keep Current Transcript", bundle: bundle) }
    static var retranscribe: String { String(localized: "Retranscribe", bundle: bundle) }
    static var batchTranscriptionConfirmationTitle: String { String(localized: "Start batch transcription?", bundle: bundle) }
    static var batchTranscriptionConfirmationDescription: String { String(
        localized: "Choose a transcription language. Audio is kept until transcription succeeds.",
        bundle: bundle
    ) }
    static var batchRetranscriptionConfirmationTitle: String { String(localized: "Retranscribe the saved recording?", bundle: bundle) }
    static var batchRetranscriptionConfirmationDescription: String { String(
        localized: "The current transcript remains available while processing and is replaced only after retranscription succeeds.",
        bundle: bundle
    ) }
    static var automaticDetectionMultilingualTitle: String { String(
        localized: "Multilingual meetings",
        bundle: bundle
    ) }
    static var automaticDetectionMultilingualDescription: String { String(
        localized: "Detects the language of each recording, allowing transcription when multiple languages are used.",
        bundle: bundle
    ) }
    static var automaticDetectionLanguagesTitle: String { String(
        localized: "Languages to detect",
        bundle: bundle
    ) }
    static var noAutomaticLanguageCandidates: String { String(
        localized: "Select at least one WhisperKit-supported language in Settings before using Auto.",
        bundle: bundle
    ) }
    static var automaticDetectionProcessingTimeTitle: String { String(
        localized: "Processing time",
        bundle: bundle
    ) }
    static var automaticDetectionProcessingTimeDescription: String { String(
        localized: """
        Language detection makes transcription take longer. \
        If the language cannot be determined, the recording is transcribed as English.
        """,
        bundle: bundle
    ) }
    static var batchLanguageModelPreparationFailed: String { String(
        localized: "Could not prepare the language detection model. Check your network connection and try again.",
        bundle: bundle
    ) }
    static var batchLanguageDetectionAudioLoadingFailed: String { String(
        localized: "Could not read the recording for language detection. Try again.",
        bundle: bundle
    ) }
    static var batchLanguageDetectionFailed: String { String(
        localized: "Could not detect the recording language. Try again.",
        bundle: bundle
    ) }

    static func batchDetectedLanguageUnsupported(_ languageIdentifier: String) -> String {
        String(localized: "The detected language is not supported for transcription: \(languageIdentifier)", bundle: bundle)
    }

    static var deleteBatchAudioAfterTranscription: String { String(
        localized: "Delete Recording Files After Transcription",
        bundle: bundle
    ) }
    static var deleteBatchAudioAfterTranscriptionDescription: String { String(
        localized: "Delete the recording files after batch transcription succeeds. They are kept if transcription fails.",
        bundle: bundle
    ) }
    static var generateSummaryAfterBatchTranscription: String { String(
        localized: "Generate Summary After Transcription",
        bundle: bundle
    ) }
    static var generateSummaryAfterBatchTranscriptionDescription: String { String(
        localized: "Automatically generate a summary when batch transcription succeeds.",
        bundle: bundle
    ) }
    static var summaryAndExport: String { String(localized: "Summary and Export", bundle: bundle) }
    static var project: String { String(localized: "Project", bundle: bundle) }
    static var summaryGenerationConfirmationTitle: String { String(localized: "Generate this summary?", bundle: bundle) }
    static var summaryGenerationConfirmationDescription: String { String(
        localized: "Review the context and export options before generating the summary.",
        bundle: bundle
    ) }
    static var regenerateSummaries: String { String(localized: "Regenerate Summaries", bundle: bundle) }
    static var regenerateSelectedSummariesConfirmationTitle: String { String(
        localized: "Regenerate selected summaries?",
        bundle: bundle
    ) }
    static var regenerateSelectedSummariesConfirmationDescription: String { String(
        localized: "Each selected meeting is regenerated independently. Existing summaries are replaced only after generation succeeds.",
        bundle: bundle
    ) }
    static var exportBatchSummaryToVault: String { String(
        localized: "Export Summary to Vault",
        bundle: bundle
    ) }
    static var exportBatchSummaryToVaultDescription: String { String(
        localized: "Write the generated summary and related files to the current Vault.",
        bundle: bundle
    ) }
    static var exportBatchSummaryToGoogleDocs: String { String(
        localized: "Export Summary to Google Docs",
        bundle: bundle
    ) }
    static var exportBatchSummaryToGoogleDocsDescription: String { String(
        localized: "Export the generated summary to the configured Google Docs folder.",
        bundle: bundle
    ) }
    static var later: String { String(localized: "Later", bundle: bundle) }
    static var discardFailedBatchRecording: String { String(localized: "Discard Failed Recording", bundle: bundle) }
    static var discardFailedBatchRecordingConfirmation: String { String(localized: "Discard this failed recording?", bundle: bundle) }
    static var discardFailedBatchRecordingDescription: String { String(
        localized: "The untranscribed audio will be deleted. Existing transcript content will be kept.",
        bundle: bundle
    ) }
    static var cancel: String { String(localized: "Cancel", bundle: bundle) }
    static func batchAudioWriteFailed(_ reason: String) -> String {
        String(localized: "Could not save the recording: \(reason)", bundle: bundle)
    }

    static var terminationPersistenceFailedTitle: String {
        String(localized: "Dahlia could not quit", bundle: bundle)
    }

    static var recordingPersistenceRetryFailed: String {
        String(localized: "The recording could not be saved. Dahlia will remain open so you can try again.", bundle: bundle)
    }

    static var batchAudioFormatUnavailable: String { String(localized: "No compatible audio format is available.", bundle: bundle) }
    static var batchRecordingAudioUnavailable: String {
        String(localized: "Recording audio is incomplete and cannot be transcribed.", bundle: bundle)
    }

    static var batchAudioRangeInvalid: String { String(localized: "The recorded audio range is invalid or damaged.", bundle: bundle) }
    static var batchAnalysisDidNotAdvance: String { String(localized: "Speech analysis could not read the recorded audio.", bundle: bundle) }

    static func batchAnalysisStalled(minutes: Int) -> String {
        let duration = localizedCount(minutes, singular: "%lld minute", plural: "%lld minutes")
        return String(
            format: String(
                localized: "Batch transcription stopped because Apple Speech made no progress for %@. The recording audio was kept for retry.",
                bundle: bundle
            ),
            duration
        )
    }

    static var assignee: String { String(localized: "Assignee", bundle: bundle) }

    // MARK: - Audio Source Mode

    static var microphone: String { String(localized: "Microphone", bundle: bundle) }
    static var mic: String { String(localized: "Mic", bundle: bundle) }
    static var system: String { String(localized: "System", bundle: bundle) }
    static var systemAudio: String { String(localized: "System Audio", bundle: bundle) }
    static var both: String { String(localized: "Both", bundle: bundle) }
    static var none: String { String(localized: "None", bundle: bundle) }
    static var sameAsSystem: String { String(localized: "Same as System", bundle: bundle) }
    static func sameAsSystem(_ deviceName: String) -> String { String(localized: "Same as System (\(deviceName))", bundle: bundle) }
    static var noComputerAudio: String { String(localized: "No computer audio", bundle: bundle) }
    static var recordComputerAudio: String { String(localized: "Record computer audio", bundle: bundle) }

    // MARK: - Settings

    static var general: String { String(localized: "General", bundle: bundle) }
    static var betaFeatures: String { String(localized: "Beta Features", bundle: bundle) }
    static var betaFeaturesDescription: String { String(
        localized: "Turn on a beta feature to show its entry points in the Dahlia toolbar and menus. Beta features may change without notice.",
        bundle: bundle
    ) }
    static var permissions: String { String(localized: "Permissions", bundle: bundle) }
    static var permissionGuideDescription: String { String(
        localized: "Review the macOS permissions Dahlia uses. Each permission controls a different feature and can be changed at any time.",
        bundle: bundle
    ) }
    static var screenAndSystemAudioPermission: String { String(
        localized: "Screen & System Audio Recording",
        bundle: bundle
    ) }
    static var screenAndSystemAudioPermissionDescription: String { String(
        localized: "Allows Dahlia to transcribe audio from speakers and meeting apps. Dahlia does not save screen video for transcription.",
        bundle: bundle
    ) }
    static var screenAndSystemAudioPermissionFooter: String { String(
        localized: """
        Microphone capture also uses ScreenCaptureKit, but macOS still requires the separate Microphone permission below. \
        You may need to restart Dahlia after changing this setting.
        """,
        bundle: bundle
    ) }
    static var microphonePermission: String { String(localized: "Microphone Permission", bundle: bundle) }
    static var microphonePermissionDescription: String { String(
        localized: "Allows Dahlia to capture and transcribe your voice from the selected microphone.",
        bundle: bundle
    ) }
    static var calendarPermission: String { String(localized: "macOS Calendar Permission", bundle: bundle) }
    static var calendarPermissionDescription: String { String(
        localized: "Allows Dahlia to read events from calendars selected in Calendar settings.",
        bundle: bundle
    ) }
    static var calendarPermissionFooter: String { String(
        localized: "Optional. Google Calendar does not use this macOS permission.",
        bundle: bundle
    ) }
    static var permissionNotDetermined: String { String(localized: "Not Requested", bundle: bundle) }
    static var permissionRequiresReview: String { String(localized: "Needs Review", bundle: bundle) }
    static var permissionGranted: String { String(localized: "Permission Granted", bundle: bundle) }
    static var permissionDenied: String { String(localized: "Permission Denied", bundle: bundle) }
    static var permissionRestricted: String { String(localized: "Restricted", bundle: bundle) }
    static var allowAccess: String { String(localized: "Allow Access", bundle: bundle) }
    static var checkAccess: String { String(localized: "Check Access", bundle: bundle) }
    static var openSystemSettings: String { String(localized: "Open System Settings", bundle: bundle) }
    static var screenCapturePermissionReviewGuidance: String { String(
        localized: "macOS does not report whether this access has never been requested or was previously denied. Check access to continue; if needed, enable Dahlia in System Settings.",
        bundle: bundle
    ) }
    static var screenCapturePermissionDeniedGuidance: String { String(
        localized: "In System Settings, enable Dahlia under Screen & System Audio Recording. Restart Dahlia if macOS asks you to.",
        bundle: bundle
    ) }
    static var microphonePermissionDeniedGuidance: String { String(
        localized: "In System Settings, enable Dahlia under Microphone.",
        bundle: bundle
    ) }
    static var calendarPermissionDeniedGuidance: String { String(
        localized: "In System Settings, give Dahlia full access under Calendars.",
        bundle: bundle
    ) }
    static var permissionRestrictedGuidance: String { String(
        localized: "This permission is restricted by this Mac or its administrator and may not be changeable in System Settings.",
        bundle: bundle
    ) }
    static var systemSettingsOpenFailed: String { String(localized: "Could Not Open System Settings", bundle: bundle) }
    static var systemSettingsOpenFailedDescription: String { String(
        localized: "Open Privacy & Security in System Settings and choose the relevant permission manually.",
        bundle: bundle
    ) }
    static var backups: String { String(localized: "Backups", bundle: bundle) }
    static var databaseBackup: String { String(localized: "Database Backup", bundle: bundle) }
    static var databaseBackupDescription: String { String(
        localized: "Backups include transcripts and other database content. Audio files and their references are excluded.",
        bundle: bundle
    ) }
    static var createBackup: String { String(localized: "Create Backup", bundle: bundle) }
    static var importBackup: String { String(localized: "Import Backup", bundle: bundle) }
    static var exportBackup: String { String(localized: "Export", bundle: bundle) }
    static var restoreBackup: String { String(localized: "Restore", bundle: bundle) }
    static var deleteBackup: String { String(localized: "Delete Backup", bundle: bundle) }
    static var backupGenerations: String { String(localized: "Backup Generations", bundle: bundle) }
    static var noBackups: String { String(localized: "No Backups", bundle: bundle) }
    static var noBackupsDescription: String { String(localized: "Create a backup to preserve the current database.", bundle: bundle) }
    static var backupCreated: String { String(localized: "Backup created.", bundle: bundle) }
    static var backupImported: String { String(localized: "Backup imported.", bundle: bundle) }
    static var backupExported: String { String(localized: "Backup exported.", bundle: bundle) }
    static var backupDeleted: String { String(localized: "Backup deleted.", bundle: bundle) }
    static var selectedBackupInvalid: String { String(localized: "The selected file is not a valid Dahlia backup.", bundle: bundle) }
    static var backupRestoreAlreadyPending: String { String(localized: "Another database restore is already pending.", bundle: bundle) }
    static var backupGenerationMissing: String { String(localized: "The selected backup generation no longer exists.", bundle: bundle) }
    static var untitledMeeting: String { String(localized: "Untitled Meeting", bundle: bundle) }

    static func resolveUnprocessedRecordings(_ count: Int) -> String {
        let format = if count == 1 {
            String(localized: "Resolve %lld unprocessed recording before continuing.", bundle: bundle)
        } else {
            String(localized: "Resolve %lld unprocessed recordings before continuing.", bundle: bundle)
        }
        return String(
            format: format,
            Int64(count)
        )
    }

    static func backupFormatUnsupported(_ version: Int) -> String {
        String(
            format: String(localized: "Backup format %lld is not supported by this version of Dahlia.", bundle: bundle),
            Int64(version)
        )
    }

    static func backupSchemaNewer(_ identifier: String) -> String {
        String(format: String(localized: "This backup uses the newer database schema %@.", bundle: bundle), identifier)
    }

    static func backupIntegrityCheckFailed(_ message: String) -> String {
        String(format: String(localized: "The backup failed its integrity check: %@", bundle: bundle), message)
    }

    static func backupRestored(schemaVersion: Int) -> String {
        String(format: String(localized: "Database restored from schema v%lld.", bundle: bundle), Int64(schemaVersion))
    }

    static func backupRestoreFailed(_ reason: String) -> String {
        String(format: String(localized: "Could not restore the database: %@", bundle: bundle), reason)
    }

    static var invalidBackup: String { String(localized: "Invalid backup", bundle: bundle) }
    static var beforeRestoreBackup: String { String(localized: "Created before restore", bundle: bundle) }
    static var deleteBackupConfirmation: String { String(localized: "Delete this backup?", bundle: bundle) }
    static var deleteBackupDescription: String { String(
        localized: "This backup generation will be permanently deleted. This cannot be undone.",
        bundle: bundle
    ) }
    static var restoreBackupConfirmation: String { String(localized: "Restore this backup?", bundle: bundle) }
    static var restoreBackupDescription: String { String(
        localized: "The current database will be backed up first, then replaced. Dahlia will restart. Audio files and app settings are not restored.",
        bundle: bundle
    ) }
    static var unprocessedRecordings: String { String(localized: "Unprocessed Recordings", bundle: bundle) }
    static var viewUnprocessedRecordings: String { String(localized: "Open Unprocessed Recordings", bundle: bundle) }
    static var finishRecordingBeforeOpeningAnotherVault: String { String(
        localized: "Finish the current recording before opening unprocessed recordings in another vault.",
        bundle: bundle
    ) }
    static var unprocessedRecordingsDescription: String { String(
        localized: "Transcribe or discard every unprocessed recording before creating or restoring a backup.",
        bundle: bundle
    ) }
    static var noUnprocessedRecordingsDescription: String { String(
        localized: "Recordings that need manual transcription will appear here.",
        bundle: bundle
    ) }
    static var awaitingTranscription: String { String(localized: "Waiting for transcription", bundle: bundle) }
    static var transcriptionInProgress: String { String(localized: "Transcription in progress", bundle: bundle) }
    static var transcriptionFailed: String { String(localized: "Transcription failed", bundle: bundle) }
    static var recordingInProgress: String { String(localized: "Recording in progress", bundle: bundle) }
    static var transcribe: String { String(localized: "Transcribe", bundle: bundle) }
    static var discardRecording: String { String(localized: "Discard", bundle: bundle) }
    static var discardUnprocessedRecordingConfirmation: String { String(localized: "Discard this recording?", bundle: bundle) }
    static var discardUnprocessedRecordingDescription: String { String(
        localized: "The unprocessed audio and any partial transcript from this recording will be permanently deleted. The meeting remains.",
        bundle: bundle
    ) }
    static var unprocessedRecordingDiscarded: String { String(localized: "Unprocessed recording discarded.", bundle: bundle) }
    static func backupGenerationDetail(schemaVersion: Int, appVersion: String, size: String) -> String {
        String(
            format: String(localized: "Schema v%lld · Dahlia %@ · %@", bundle: bundle),
            Int64(schemaVersion),
            appVersion,
            size
        )
    }

    static var checkForUpdates: String { String(localized: "Check for Updates…", bundle: bundle) }
    static var update: String { String(localized: "Update", bundle: bundle) }
    static var updateAvailable: String { String(localized: "Update Available", bundle: bundle) }

    static func updateAvailableVersion(_ version: String) -> String {
        String(format: String(localized: "Dahlia %@ is available. Click to view the update.", bundle: bundle), version)
    }

    static var app: String { String(localized: "App", bundle: bundle) }
    static var integrations: String { String(localized: "Integrations", bundle: bundle) }
    static var ai: String { String(localized: "AI", bundle: bundle) }
    static var advanced: String { String(localized: "Advanced", bundle: bundle) }
    static var modelProvider: String { String(localized: "Model Provider", bundle: bundle) }
    static var diagnostics: String { String(localized: "Diagnostics", bundle: bundle) }
    static var notifications: String { String(localized: "Notifications", bundle: bundle) }
    static var calendar: String { String(localized: "Calendar", bundle: bundle) }
    static var cloudStorage: String { String(localized: "Cloud Storage", bundle: bundle) }
    static var aiSummary: String { String(localized: "AI Summary", bundle: bundle) }
    static var developerSettings: String { String(localized: "Developer Settings", bundle: bundle) }
    static var vault: String { String(localized: "Vault", bundle: bundle) }
    static var currentVault: String { String(localized: "Current Vault", bundle: bundle) }
    static var mcp: String { String(localized: "MCP", bundle: bundle) }
    static var copyCommand: String { String(localized: "Copy Command", bundle: bundle) }
    static var copyRemoveCommand: String { String(localized: "Copy Remove Command", bundle: bundle) }
    static var copied: String { String(localized: "Copied", bundle: bundle) }
    static var codexCLI: String { String(localized: "Codex CLI", bundle: bundle) }
    static var claudeCode: String { String(localized: "Claude Code", bundle: bundle) }
    static var mcpPreview: String { String(localized: "Command Preview", bundle: bundle) }
    static var mcpClient: String { String(localized: "Client", bundle: bundle) }
    static var mcpAllowWriteAccess: String { String(localized: "Allow Write Access", bundle: bundle) }
    static var mcpConfigurationOutput: String { String(localized: "Configuration", bundle: bundle) }
    static var mcpJSON: String { String(localized: "mcp.json", bundle: bundle) }
    static var copyMCPJSON: String { String(localized: "Copy mcp.json", bundle: bundle) }
    static var mcpReRegistrationHelp: String { String(localized: "Re-register Dahlia", bundle: bundle) }
    static var mcpReRegistrationHelpDescription: String { String(
        localized: "If Dahlia is already registered, run this remove command before the registration command.",
        bundle: bundle
    ) }
    static var mcpHelperUnavailable: String { String(
        localized: "The MCP helper is not available in this app build.",
        bundle: bundle
    ) }
    static var selectVaultForMCP: String { String(localized: "Select a vault before configuring MCP.", bundle: bundle) }
    static var mcpFooter: String { String(
        // swiftlint:disable:next line_length
        localized: "The agent can read Meeting content and customer intelligence, including names and email addresses, from the selected Vault. Write access also allows creating, updating, and deleting customer intelligence, reorganizing Projects and meeting assignments, and replacing stored meeting summaries.",
        bundle: bundle
    ) }
    static func registrationCommand(_ name: String) -> String {
        String(format: String(localized: "%@ registration command", bundle: bundle), name)
    }

    static var currentVaultDescription: String { String(localized: "Choose the vault used for recordings and sync.", bundle: bundle) }
    static var noVaultSelected: String { String(localized: "No vault selected", bundle: bundle) }
    static var dahliaAccount: String { String(localized: "Dahlia Account", bundle: bundle) }
    static var dahliaAccountDescription: String { String(localized: "Manage your account and billing.", bundle: bundle) }
    static var comingSoon: String { String(localized: "Coming Soon", bundle: bundle) }
    static var loadingVaults: String { String(localized: "Loading Vaults…", bundle: bundle) }
    static var removingVault: String { String(localized: "Removing Vault…", bundle: bundle) }
    static var appearance: String { String(localized: "Appearance", bundle: bundle) }
    static var display: String { String(localized: "Display", bundle: bundle) }
    static var meetingSidebar: String { String(localized: "Meeting Sidebar", bundle: bundle) }
    static var sidebarDisplayStyle: String { String(localized: "Sidebar Display Style", bundle: bundle) }
    static var sidebarDisplayStyleDescription: String { String(
        localized: "Controls how meetings appear in the sidebar.",
        bundle: bundle
    ) }
    static var standard: String { String(localized: "Standard", bundle: bundle) }
    static var compact: String { String(localized: "Compact", bundle: bundle) }
    static var appLanguage: String { String(localized: "App Language", bundle: bundle) }
    static var appLanguageDescription: String { String(localized: "Set the display language for the app.", bundle: bundle) }
    static var followSystem: String { String(localized: "Follow System", bundle: bundle) }
    static var notificationSettingsDescription: String { String(
        localized: "Choose one or both conditions. Calendar notifications use events from enabled calendar sources.",
        bundle: bundle
    ) }
    static var enableMeetingNotificationsToChooseConditions: String { String(
        localized: "Turn on meeting notifications to choose notification conditions.",
        bundle: bundle
    ) }
    static var transcriptionMethod: String { String(localized: "Transcription Method", bundle: bundle) }
    static var realtimeTranscription: String { String(localized: "Real-time Transcription", bundle: bundle) }
    static var batchTranscription: String { String(localized: "Batch Transcription", bundle: bundle) }
    static var realtimeTranscriptionDescription: String { String(
        localized: "Show the transcript while recording. Accuracy may be lower than transcription after recording, and audio files are not saved.",
        bundle: bundle
    ) }
    static var batchTranscriptionDescription: String { String(
        localized: "Record audio first, then create a higher-accuracy transcript after recording stops.",
        bundle: bundle
    ) }
    static var batchTranscriptionStallTimeout: String { String(localized: "No-progress Timeout", bundle: bundle) }
    static var batchTranscriptionStallTimeoutDescription: String { String(
        localized: "Stop batch transcription when Apple Speech makes no progress for this long.",
        bundle: bundle
    ) }

    static func batchTranscriptionStallTimeoutMinutes(_ minutes: Int) -> String {
        localizedCount(minutes, singular: "%lld minute", plural: "%lld minutes")
    }

    static var retainBatchAudio: String { String(localized: "Keep Audio After Transcription", bundle: bundle) }
    static var retainBatchAudioDescription: String { String(
        localized: "Keep the protected audio in Dahlia after batch transcription succeeds.",
        bundle: bundle
    ) }
    static var liveSubtitleTranslation: String { String(localized: "Live Subtitle Translation", bundle: bundle) }
    static var liveSubtitleTranslationDescription: String { String(
        localized: "Translate live subtitles into the selected target language. With real-time transcription, translations are also saved.",
        bundle: bundle
    ) }
    static var translationTargetLanguage: String { String(localized: "Target Language", bundle: bundle) }
    static var liveSubtitleTranslationTargetLanguageDescription: String { String(
        localized: "Choose which language translated live subtitles should use.",
        bundle: bundle
    ) }
    static var liveSubtitleTranslationDisabledForMatchingTranscriptionLanguage: String { String(
        localized: "Translation is automatically disabled when the target language matches the transcription language.",
        bundle: bundle
    ) }
    static var liveSubtitleTranslationDisabledForMatchingLiveSubtitleLanguage: String { String(
        localized: "Translation is automatically disabled when the target language matches the live subtitle language.",
        bundle: bundle
    ) }
    static var enableLiveSubtitleTranslationToChooseLanguage: String { String(
        localized: "Turn on live subtitle translation to choose a target language.",
        bundle: bundle
    ) }
    static var developerSettingsDescription: String { String(
        localized: "Configure these only when your organization requires a company-managed Google OAuth client. Otherwise, leave them blank to use the app defaults.",
        bundle: bundle
    ) }
    static var googleOAuthClientIDOverride: String { String(localized: "Google OAuth Client ID", bundle: bundle) }
    static var googleOAuthClientIDOverrideDescription: String { String(
        localized: "Leave blank to use the app's default client ID.",
        bundle: bundle
    ) }
    static var googleOAuthClientSecretOverride: String { String(localized: "Google OAuth Client Secret", bundle: bundle) }
    static var googleOAuthClientSecretOverrideDescription: String { String(
        localized: "Optional. Stored securely in Keychain. Leave blank to use the app's default client secret.",
        bundle: bundle
    ) }
    static var googleOAuthOverrideReconnectNotice: String { String(
        localized: "Reconnect Google services after changing OAuth credentials.",
        bundle: bundle
    ) }
    static var googleCalendar: String { String(localized: "Google Calendar", bundle: bundle) }
    static var macOSCalendar: String { String(localized: "macOS Calendar", bundle: bundle) }
    static var calendarSource: String { String(localized: "Calendar Source", bundle: bundle) }
    static var calendarSourceDescription: String { String(
        localized: "Choose which calendar service provides upcoming events.",
        bundle: bundle
    ) }
    static var calendarSources: String { String(localized: "Calendar Sources", bundle: bundle) }
    static var calendarSourcesDescription: String { String(
        localized: "Choose which calendar services provide upcoming events.",
        bundle: bundle
    ) }
    static var calendarEventsToInclude: String { String(localized: "Events to Include", bundle: bundle) }
    static var calendarEventsToIncludeDescription: String { String(
        localized: "Turn on the event types to show in Home, the menu bar, and calendar notifications.",
        bundle: bundle
    ) }
    static var calendarFilterAllDayEvents: String { String(localized: "All-day events", bundle: bundle) }
    static var calendarIncludeAllDayEventsDescription: String { String(
        localized: "Include events marked as all-day.",
        bundle: bundle
    ) }
    static var calendarFilterUserOnlyEvents: String { String(localized: "Events without other attendees", bundle: bundle) }
    static var calendarIncludeUserOnlyEventsDescription: String { String(
        localized: "Include events with no attendees other than you.",
        bundle: bundle
    ) }
    static var calendarFilterEventsWithoutMeetingURL: String { String(
        localized: "Events without a meeting URL",
        bundle: bundle
    ) }
    static var calendarIncludeEventsWithoutMeetingURLDescription: String { String(
        localized: "Include events that do not have a supported meeting URL.",
        bundle: bundle
    ) }
    static var calendarFilterDeclinedEvents: String { String(localized: "Declined events", bundle: bundle) }
    static var calendarIncludeDeclinedEventsDescription: String { String(
        localized: "Include events you declined.",
        bundle: bundle
    ) }
    static var calendarFilterOutOfOfficeEvents: String { String(localized: "OOO / OOTO events", bundle: bundle) }
    static var calendarIncludeOutOfOfficeEventsDescription: String { String(
        localized: "Include out-of-office events and events whose title includes OOO or OOTO.",
        bundle: bundle
    ) }
    static var calendarNoEventsMatchFiltersTitle: String { String(
        localized: "No events match your inclusion settings",
        bundle: bundle
    ) }
    static var calendarNoEventsMatchFiltersMessage: String { String(
        localized: "Upcoming events were found, but none match the event types you chose to include.",
        bundle: bundle
    ) }
    static var googleCalendarSourceDescription: String { String(
        localized: "Show events from Google Calendar.",
        bundle: bundle
    ) }
    static var macOSCalendarSourceDescription: String { String(
        localized: "Show events from the Calendar app on this Mac.",
        bundle: bundle
    ) }
    static var calendarScheduleTitle: String { String(localized: "Upcoming schedule", bundle: bundle) }
    static var showUpcomingSchedule: String { String(localized: "Show Upcoming Schedule", bundle: bundle) }
    static var calendarAutoRecording: String { String(localized: "Auto-record", bundle: bundle) }
    static var calendarAutoRecordingScheduled: String { String(localized: "Auto-record scheduled", bundle: bundle) }
    static var calendarAutoRecordingHelp: String { String(
        localized: "Automatically start recording when this event begins.",
        bundle: bundle
    ) }

    static func calendarEventOrigin(_ title: String) -> String {
        String(localized: "Calendar event: \(title)", bundle: bundle)
    }

    static var googleDrive: String { String(localized: "Google Drive", bundle: bundle) }
    static var notion: String { String(localized: "Notion", bundle: bundle) }
    static var notionExportDescription: String { String(localized: "Export summaries to Notion.", bundle: bundle) }
    static var googleCalendarSettingsDescription: String { String(
        localized: "Connect a Google account and choose which calendars appear on Home.",
        bundle: bundle
    ) }
    static var macOSCalendarSettingsDescription: String { String(
        localized: "Use events from the Calendar app on this Mac.",
        bundle: bundle
    ) }
    static var googleDocsSettingsDescription: String { String(
        localized: "Connect a Google account to export summaries, including images, to Google Docs from the Share menu.",
        bundle: bundle
    ) }
    static var googleCalendarDisplayCalendars: String { String(localized: "Display Calendars", bundle: bundle) }
    static var googleCalendarDisplayCalendarsDescription: String { String(
        localized: "Only selected calendars are shown on Home.",
        bundle: bundle
    ) }
    static var macOSCalendarDisplayCalendarsDescription: String { googleCalendarDisplayCalendarsDescription }
    static var googleCalendarConnect: String { String(localized: "Connect", bundle: bundle) }
    static var googleCalendarDisconnect: String { String(localized: "Disconnect", bundle: bundle) }
    static var googleCalendarConnectDescription: String { String(
        localized: "Sign in with Google to load your upcoming schedule.",
        bundle: bundle
    ) }
    static var googleCalendarConnected: String { String(localized: "Connected", bundle: bundle) }
    static var googleCalendarNotConnected: String { String(localized: "No Google account connected", bundle: bundle) }
    static var googleDriveConnect: String { googleCalendarConnect }
    static var googleDriveDisconnect: String { googleCalendarDisconnect }
    static var googleDocsConnectDescription: String { String(
        localized: "Sign in with Google to export summaries to Google Docs.",
        bundle: bundle
    ) }
    static var googleCalendarOAuthDisclosureTitle: String { String(localized: "Connect Google Calendar", bundle: bundle) }
    static var googleDriveOAuthDisclosureTitle: String { String(localized: "Connect Google Drive", bundle: bundle) }
    static var googleCalendarOAuthDisclosureOverview: String { String(
        localized: """
        Dahlia requests read-only access to your Google account and the upcoming events in calendars you choose.
        """,
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureOverview: String { String(
        localized: """
        Dahlia requests access only to the Google Drive files and folders it creates or that you explicitly use with Dahlia.
        """,
        bundle: bundle
    ) }
    static var googleOAuthDisclosureDataAccess: String { String(localized: "Data Dahlia Accesses", bundle: bundle) }
    static var googleCalendarOAuthDisclosureAccess: String { String(
        localized: """
        Your Google account name and email address, calendar names, and event titles, descriptions, dates, attendance status, and meeting links.
        """,
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureAccess: String { String(
        localized: """
        Your Google account name and email address, a Dahlia folder, and Google Docs summaries created by Dahlia. \
        Other Drive files are not accessible to Dahlia.
        """,
        bundle: bundle
    ) }
    static var googleOAuthDisclosureUseAndStorage: String { String(localized: "How Dahlia Uses and Stores It", bundle: bundle) }
    static var googleCalendarOAuthDisclosureUseAndStorage: String { String(
        localized: """
        OAuth tokens and your account ID, name, and email address are stored in Keychain. Upcoming events are shown in Dahlia. \
        Auto-recording stores the selected event occurrence identifier and its start and end dates in local settings until the recording attempt or event end. \
        Linked event details are stored in the local meeting database and any database backups you create while a saved meeting refers to them.
        """,
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureUseAndStorage: String { String(
        localized: """
        OAuth tokens and your account ID, name, and email address are stored in Keychain. \
        The export folder and account IDs are stored in local settings. \
        Exported document URLs and IDs are stored with the related meeting and in any database backups you create.
        """,
        bundle: bundle
    ) }
    static var googleOAuthDisclosureExternalSharing: String { String(localized: "External Sharing", bundle: bundle) }
    static var googleCalendarOAuthDisclosureExternalSharing: String { String(
        localized: """
        When you generate a summary, enable automatic summary generation, or use AI chat, \
        the linked event's title, description, and dates may be sent \
        to the AI provider you configured. Dahlia does not use Google data to train general-purpose AI models.
        """,
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureExternalSharing: String { String(
        localized: """
        When you request an export, the summary and included images are sent directly from this Mac to Google Drive. \
        Dahlia does not send unrelated Drive content to an AI provider or developer server.
        """,
        bundle: bundle
    ) }
    static var googleOAuthDisclosureManageAndDelete: String { String(localized: "Manage and Delete", bundle: bundle) }
    static var googleCalendarOAuthDisclosureDeletion: String { String(
        localized: """
        Disconnecting Calendar or Drive removes both local OAuth sessions and attempts to revoke all Dahlia Google access, \
        which disconnects both services and clears saved Calendar and Drive selection identifiers. \
        Delete linked meetings to remove saved calendar details from the active database, and delete database backups separately.
        """,
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureDeletion: String { String(
        localized: """
        Disconnecting Calendar or Drive removes both local OAuth sessions and attempts to revoke all Dahlia Google access, \
        which disconnects both services and clears saved Calendar and Drive selection identifiers. \
        Exported documents remain in Drive; delete them there, and delete related meetings and database backups to remove local document references.
        """,
        bundle: bundle
    ) }
    static var viewPrivacyPolicy: String { String(localized: "View Privacy Policy", bundle: bundle) }
    static var continueToGoogle: String { String(localized: "Continue to Google", bundle: bundle) }
    static var googleDocsConnected: String { String(localized: "Google Docs connected", bundle: bundle) }
    static var googleDocsNotConnected: String { googleCalendarNotConnected }
    static var googleDriveExportFolder: String { String(localized: "Export Folder", bundle: bundle) }
    static var openInGoogleDrive: String { String(localized: "Open in Google Drive", bundle: bundle) }
    static var myDrive: String { String(localized: "My Drive", bundle: bundle) }
    static var googleDriveExportDestinationDescription: String { String(
        localized: "On first connection, Dahlia creates a Dahlia folder directly under My Drive and exports Google Docs into it. The export destination is fixed to this folder.",
        bundle: bundle
    ) }
    static var googleDriveExportFolderNotConfigured: String { String(
        localized: "The Google Drive export folder has not been configured.",
        bundle: bundle
    ) }
    static var googleDriveExportFolderConfigurationFailed: String { String(
        localized: "Could not configure the Google Drive export folder.",
        bundle: bundle
    ) }
    static var openCloudStorageSettings: String { String(localized: "Open Cloud Storage Settings", bundle: bundle) }
    static var googleCalendarNoCalendars: String { String(localized: "No calendars are available for this Google account.", bundle: bundle) }
    static var macOSCalendarNoCalendars: String { String(localized: "No calendars are available in macOS Calendar.", bundle: bundle) }
    static var calendarLoading: String { String(localized: "Loading calendars…", bundle: bundle) }
    static var googleCalendarLoading: String { String(localized: "Loading Google Calendar…", bundle: bundle) }
    static var macOSCalendarLoading: String { String(localized: "Loading macOS Calendar…", bundle: bundle) }
    static var googleCalendarRetry: String { String(localized: "Retry", bundle: bundle) }
    static var googleCalendarAllDay: String { String(localized: "All day", bundle: bundle) }
    static var calendarAllDay: String { googleCalendarAllDay }
    static var googleCalendarClientIDMissingTitle: String { String(localized: "Google Calendar is not configured", bundle: bundle) }
    static var googleCalendarClientIDMissingMessage: String { String(
        localized: "Set a Google OAuth client ID in Developer Settings before connecting Google Calendar.",
        bundle: bundle
    ) }
    static var googleCalendarSignInRequiredTitle: String { String(localized: "Connect Google Calendar", bundle: bundle) }
    static var googleCalendarScheduleSignInRequiredMessage: String { String(
        localized: "Connect Google Calendar from Settings to show your upcoming events here.",
        bundle: bundle
    ) }
    static var googleCalendarSelectionRequiredTitle: String { String(localized: "Choose calendars to show", bundle: bundle) }
    static var calendarSelectionRequiredTitle: String { googleCalendarSelectionRequiredTitle }
    static var googleCalendarSelectionRequiredMessage: String { String(
        localized: "Select at least one calendar in Settings to show events on Home.",
        bundle: bundle
    ) }
    static var calendarSelectionRequiredMessage: String { googleCalendarSelectionRequiredMessage }
    static var googleCalendarScheduleSelectionRequiredMessage: String { String(
        localized: "Select at least one calendar in Settings to show events here.",
        bundle: bundle
    ) }
    static var calendarScheduleSelectionRequiredMessage: String { googleCalendarScheduleSelectionRequiredMessage }
    static var calendarNoSourcesEnabledTitle: String { String(localized: "No calendar sources enabled", bundle: bundle) }
    static var calendarNoSourcesEnabledMessage: String { String(
        localized: "Enable at least one calendar source in Settings to show upcoming events.",
        bundle: bundle
    ) }
    static var googleCalendarNoUpcomingEventsTitle: String { String(localized: "No upcoming events", bundle: bundle) }
    static var googleCalendarNoUpcomingEventsMessage: String { String(
        localized: "There are no events in the next 7 days for the selected calendars.",
        bundle: bundle
    ) }
    static var calendarNoUpcomingEventsMessage: String { googleCalendarNoUpcomingEventsMessage }
    static var googleCalendarLoadFailedTitle: String { String(localized: "Could not load Google Calendar", bundle: bundle) }
    static var macOSCalendarLoadFailedTitle: String { String(localized: "Could not load macOS Calendar", bundle: bundle) }
    static var macOSCalendarAccessRequiredTitle: String { String(localized: "Allow macOS Calendar access", bundle: bundle) }
    static var macOSCalendarAccessRequiredMessage: String { String(
        localized: "Allow Calendar access to show upcoming events from this Mac.",
        bundle: bundle
    ) }
    static var macOSCalendarAllowAccess: String { String(localized: "Allow Access", bundle: bundle) }
    static var macOSCalendarAccessDeniedTitle: String { String(localized: "macOS Calendar access is denied", bundle: bundle) }
    static var macOSCalendarAccessDeniedMessage: String { String(
        localized: "Allow Dahlia to access Calendars in System Settings > Privacy & Security > Calendars.",
        bundle: bundle
    ) }
    static var macOSCalendarAccessGranted: String { String(localized: "Calendar access granted", bundle: bundle) }
    static var macOSCalendarAccessNotGranted: String { String(localized: "Calendar access not granted", bundle: bundle) }
    static var macOSCalendarConnectDescription: String { String(
        localized: "Allow access to load your upcoming schedule from Calendar.",
        bundle: bundle
    ) }
    static var macOSCalendarConnected: String { String(localized: "macOS Calendar connected", bundle: bundle) }
    static var macOSCalendarUnexpectedError: String { String(localized: "Unexpected response from macOS Calendar", bundle: bundle) }
    static var macOSCalendarUntitledCalendar: String { String(localized: "Untitled calendar", bundle: bundle) }
    static var macOSCalendarUntitledEvent: String { String(localized: "Untitled event", bundle: bundle) }
    static var googleCalendarMissingPresentingWindow: String { String(
        localized: "No window is available to present Google sign-in.",
        bundle: bundle
    ) }
    static var googleAccountNoPreviousSession: String { String(localized: "No previous Google session was found.", bundle: bundle) }
    static var googleAccountAuthorizationTimedOut: String { String(
        localized: "Google sign-in timed out. Please try again.",
        bundle: bundle
    ) }
    static var googleCalendarClientSecretMissingMessage: String { String(
        localized: "This Google OAuth client requires a client secret. Enter the value from Google Cloud Console in Developer Settings and relaunch Dahlia.",
        bundle: bundle
    ) }
    static var googleAccountClientIDMissingMessage: String { String(
        localized: "Set a Google OAuth client ID in Developer Settings before connecting Google services.",
        bundle: bundle
    ) }
    static var googleAccountClientSecretMissingMessage: String { googleCalendarClientSecretMissingMessage }
    static var googleCalendarKeychainConfigurationMessage: String { String(
        localized: "Google sign-in could not access Keychain. Rebuild the app with ./scripts/run-dev.sh so it is code signed with the required Keychain entitlements.",
        bundle: bundle
    ) }
    static var googleAccountKeychainConfigurationMessage: String { googleCalendarKeychainConfigurationMessage }
    static var googleCalendarUnknownAccount: String { String(localized: "Google Account", bundle: bundle) }
    static var googleAccountUnknown: String { googleCalendarUnknownAccount }
    static var googleAccountMissingPresentingWindow: String { googleCalendarMissingPresentingWindow }
    static var googleAccountUnexpectedResponse: String { String(localized: "Unexpected response from Google", bundle: bundle) }
    static func googleAccountHTTPError(_ code: Int, _ detail: String) -> String { String(
        localized: "Google HTTP \(code): \(detail)",
        bundle: bundle
    ) }
    static var googleAccountConnectedWithoutCalendar: String { String(
        localized: "Google account connected, but Calendar access has not been granted yet.",
        bundle: bundle
    ) }
    static var googleCalendarUntitledEvent: String { String(localized: "Untitled event", bundle: bundle) }
    static var googleCalendarUnexpectedResponse: String { String(localized: "Unexpected response from Google Calendar", bundle: bundle) }
    static func googleCalendarHTTPError(_ code: Int, _ detail: String) -> String { String(
        localized: "Google Calendar HTTP \(code): \(detail)",
        bundle: bundle
    ) }
    static func googleCalendarInvalidDate(_ value: String) -> String { String(
        localized: "Could not parse Google Calendar date: \(value)",
        bundle: bundle
    ) }
    static var googleDriveUnexpectedResponse: String { String(localized: "Unexpected response from Google Drive", bundle: bundle) }
    static func googleDriveHTTPError(_ code: Int, _ detail: String) -> String { String(
        localized: "Google Drive HTTP \(code): \(detail)",
        bundle: bundle
    ) }

    // MARK: - Vault Picker

    static var addVault: String { String(localized: "Add Vault", bundle: bundle) }
    static var registeredVaults: String { String(localized: "Registered Vaults", bundle: bundle) }
    static var openFolderAsVault: String { String(localized: "Open Folder as Vault", bundle: bundle) }
    static var openFolderAsVaultDescription: String { String(localized: "Select an existing folder to use as a vault.", bundle: bundle) }
    static var removeVault: String { String(localized: "Remove Vault", bundle: bundle) }
    static var currentVaultRemoveDescription: String { String(
        localized: "Open a different vault before removing this one.",
        bundle: bundle
    ) }
    static func removeVaultConfirmation(_ name: String) -> String { String(localized: "Remove \(name)?", bundle: bundle) }
    static var removeVaultConfirmationDescription: String { String(
        localized: """
        Dahlia will remove this vault and its meeting history from the app. \
        Audio files managed outside the vault folder will also be deleted. \
        Files inside the vault folder are not changed.
        """,
        bundle: bundle
    ) }
    static var vaultDetails: String { String(localized: "Vault Details", bundle: bundle) }
    static var vaultName: String { String(localized: "Vault Name", bundle: bundle) }
    static func renameVault(_ name: String) -> String { String(localized: "Rename \(name)", bundle: bundle) }
    static var openVault: String { String(localized: "Open Vault", bundle: bundle) }
    static var openVaultDescription: String { String(localized: "Use this vault for recordings and sync.", bundle: bundle) }
    static var selectVaultDescription: String { String(localized: "Select a vault to view its details.", bundle: bundle) }
    static var noVaults: String { String(localized: "No Vaults", bundle: bundle) }
    static var noVaultsDescription: String { String(
        localized: "Add a folder to start recording and syncing meetings.",
        bundle: bundle
    ) }
    static var vaultOperationFailed: String { String(localized: "Vault Operation Failed", bundle: bundle) }
    static var vaultFolderSelectionFailed: String { String(localized: "Could not select the vault folder.", bundle: bundle) }
    static var vaultLoadFailed: String { String(localized: "Could not load vaults.", bundle: bundle) }
    static var vaultAddFailed: String { String(localized: "Could not add the vault.", bundle: bundle) }
    static var vaultRenameFailed: String { String(localized: "Could not rename the vault.", bundle: bundle) }
    static var vaultRemoveFailed: String { String(localized: "Could not remove the vault.", bundle: bundle) }
    static var open: String { String(localized: "Open", bundle: bundle) }
    static var loadingLanguages: String { String(localized: "Loading supported languages...", bundle: bundle) }
    static var searchLanguages: String { String(localized: "Search languages...", bundle: bundle) }
    static var noMatchingLanguages: String { String(localized: "No matching languages", bundle: bundle) }
    static func languagesSelected(_ count: Int) -> String { String(localized: "\(count) languages selected", bundle: bundle) }
    static func additionalLanguages(_ count: Int) -> String { String(localized: "\(count) more languages", bundle: bundle) }
    static var transcriptionLanguages: String { String(localized: "Transcription Languages", bundle: bundle) }
    static var appLanguages: String { String(localized: "App Languages", bundle: bundle) }
    static var appLanguagesDescription: String { String(
        localized: "Limits languages shown for transcription and live subtitles, automatic language detection, and screenshot text extraction.",
        bundle: bundle
    ) }
    static var imageTextLanguages: String { String(localized: "Screenshot Text Languages", bundle: bundle) }
    static var imageTextLanguagesDescription: String { String(
        localized: "Codex uses the app languages selected in Language settings as hints when extracting screenshot text.",
        bundle: bundle
    ) }
    static var openLanguageSettings: String { String(localized: "Open Language Settings", bundle: bundle) }
    static var recordedLanguages: String { String(localized: "Recorded Languages", bundle: bundle) }
    static var transcriptionLanguage: String { String(localized: "Transcription Language", bundle: bundle) }
    static var transcriptionLanguageDescription: String { String(
        localized: "This language is used for the final transcript. Changing the language in the recording panel does not change it.",
        bundle: bundle
    ) }
    static var liveSubtitleLanguage: String { String(localized: "Live Subtitle Language", bundle: bundle) }
    static var liveSubtitleLanguageFollowsTranscription: String { String(
        localized: "With real-time transcription, live subtitles use the transcription language.",
        bundle: bundle
    ) }
    static var languageRange: String { String(localized: "Language Range", bundle: bundle) }
    static var allSupportedLanguages: String { String(localized: "All Supported Languages", bundle: bundle) }
    static var selectedLanguages: String { String(localized: "Selected Languages", bundle: bundle) }
    static var allTranscriptionLanguagesDescription: String { String(
        localized: "All Apple Speech languages appear in pickers. Automatic detection uses the languages also supported by WhisperKit.",
        bundle: bundle
    ) }
    static var selectedTranscriptionLanguagesDescription: String { String(
        localized: "Selected languages appear in pickers, and WhisperKit-supported selections become automatic detection candidates.",
        bundle: bundle
    ) }

    // MARK: - Settings (LLM)

    static var model: String { String(localized: "Model", bundle: bundle) }
    static var codexHelperNotBundled: String { String(
        localized: "The bundled Codex helper is unavailable. Run Dahlia with scripts/run-dev.sh or install a signed app build.",
        bundle: bundle
    ) }
    static func codexLaunchFailed(_ detail: String) -> String { String(
        localized: "Could not start Codex: \(detail)",
        bundle: bundle
    ) }
    static var codexNotLoggedIn: String { String(
        localized: "Codex is not signed in. Open Model Provider in Settings and sign in, then try again.",
        bundle: bundle
    ) }
    static func codexLoginFailed(_ detail: String) -> String { String(
        localized: "Codex sign-in failed: \(detail)",
        bundle: bundle
    ) }
    static var codexLoginFailedWithoutDetail: String { String(localized: "Codex sign-in failed.", bundle: bundle) }
    static var codexLoginPageCouldNotOpen: String { String(
        localized: "Could not open the Codex sign-in page.",
        bundle: bundle
    ) }
    static var codexProcessExited: String { String(localized: "Codex app-server exited unexpectedly.", bundle: bundle) }
    static func codexProcessExitedWithDetail(_ detail: String) -> String { String(
        localized: "Codex app-server exited unexpectedly: \(detail)",
        bundle: bundle
    ) }
    static func codexRequestTimedOut(_ operation: String) -> String { String(
        localized: "Codex did not respond in time (\(operation)). Try again.",
        bundle: bundle
    ) }
    static var codexInvalidResponse: String { String(localized: "Codex returned an invalid response.", bundle: bundle) }
    static var codexOutputLineTooLarge: String { String(
        localized: "Codex returned an output line larger than Dahlia's safety limit.",
        bundle: bundle
    ) }
    static func codexRequestFailed(_ detail: String) -> String { String(
        localized: "Codex request failed: \(detail)",
        bundle: bundle
    ) }
    static var codexTurnFailed: String { String(localized: "Codex could not complete the request.", bundle: bundle) }
    static var codexTurnInterrupted: String { String(localized: "Codex generation was interrupted.", bundle: bundle) }
    static var codexBackendResetForSafety: String {
        String(localized: "The AI backend was restarted to stop an unconfirmed operation safely.", bundle: bundle)
    }

    static var codexApprovalNoLongerPending: String {
        String(localized: "This approval request is no longer pending.", bundle: bundle)
    }

    static var codexUnknownError: String { String(localized: "Unknown Codex app-server error.", bundle: bundle) }
    static var codexVersion: String { String(localized: "Codex Version", bundle: bundle) }
    static var account: String { String(localized: "Account", bundle: bundle) }
    static var provider: String { String(localized: "Provider", bundle: bundle) }
    static var aiAccountDescription: String { String(
        localized: "Choose the account used by Codex.",
        bundle: bundle
    ) }
    static var aiAccountSettingsDescription: String { String(
        localized: "AI summaries use the selected account and its available models.",
        bundle: bundle
    ) }
    static var chatGPTSubscription: String { String(localized: "ChatGPT Subscription", bundle: bundle) }
    static var databricks: String { String(localized: "Databricks", bundle: bundle) }
    static var codexAccount: String { String(localized: "Codex Account", bundle: bundle) }
    static var codexAccountDescription: String { String(
        localized: "Dahlia stores a separate Codex sign-in for this app. Signing in opens your browser.",
        bundle: bundle
    ) }
    static var codexSignedIn: String { String(localized: "Signed in to Codex", bundle: bundle) }
    static func codexSignedInAs(_ account: String) -> String { String(
        localized: "Signed in to Codex as \(account)",
        bundle: bundle
    ) }
    static var codexNotSignedIn: String { String(localized: "Not signed in to Codex", bundle: bundle) }
    static var codexSignInNotRequired: String { String(localized: "Codex does not require sign-in", bundle: bundle) }
    static var signInWithChatGPT: String { String(localized: "Sign in with ChatGPT", bundle: bundle) }
    static var codexWaitingForBrowserSignIn: String { String(localized: "Waiting for browser sign-in…", bundle: bundle) }
    static var cancelSignIn: String { String(localized: "Cancel Sign-In", bundle: bundle) }
    static var signOut: String { String(localized: "Sign Out", bundle: bundle) }
    static var databricksProfile: String { String(localized: "Databricks CLI Profile", bundle: bundle) }
    static var databricksProfileName: String { String(localized: "Databricks CLI Profile Name", bundle: bundle) }
    static var databricksProfileNameDescription: String { String(
        localized: "Enter the name used to save this sign-in in Databricks CLI.",
        bundle: bundle
    ) }
    static func databricksProfileAlreadyExists(_ name: String) -> String { String(
        localized: "A Databricks CLI profile named \(name) already exists for another workspace or authentication method.",
        bundle: bundle
    ) }
    static var databricksProfileDescription: String { String(
        localized: "Codex obtains the workspace and credentials from this Databricks CLI profile.",
        bundle: bundle
    ) }
    static var refreshDatabricksProfiles: String { String(localized: "Refresh Profiles", bundle: bundle) }
    static var noDatabricksProfiles: String { String(
        localized: "No Databricks workspaces are connected yet.",
        bundle: bundle
    ) }
    static var databricksCLINotInstalled: String { String(
        localized: "Databricks CLI was not found. Install it to connect a workspace.",
        bundle: bundle
    ) }
    static var installDatabricksCLI: String { String(localized: "Install Databricks CLI", bundle: bundle) }
    static var databricksCLIInstallOverview: String { String(
        localized: "Dahlia uses the official Databricks CLI for browser sign-in and token refresh. The CLI is installed separately and is subject to the Databricks License and Privacy Notice.",
        bundle: bundle
    ) }
    static var databricksCLIInstallCommand: String { String(localized: "Homebrew Command", bundle: bundle) }
    static var databricksCLIInstallCommandDescription: String { String(
        localized: "Terminal runs this visible command. Dahlia does not bundle or download the CLI.",
        bundle: bundle
    ) }
    static var installInTerminal: String { String(localized: "Install in Terminal", bundle: bundle) }
    static var viewOfficialInstallGuide: String { String(localized: "View Official Installation Guide", bundle: bundle) }
    static var viewDatabricksLicense: String { String(localized: "View Databricks License", bundle: bundle) }
    static var viewDatabricksPrivacyNotice: String { String(localized: "View Databricks Privacy Notice", bundle: bundle) }
    static var databricksCLIInstallation: String { String(localized: "Databricks CLI Installation", bundle: bundle) }
    static var databricksCLIInstallCommandCopied: String { String(
        localized: "Dahlia could not control Terminal. The installation command was copied and Terminal was opened. Paste the command and press Return.",
        bundle: bundle
    ) }
    static var databricksCLIInstallFailed: String { String(
        localized: "Dahlia could not open Terminal. Use the official installation guide to install Databricks CLI.",
        bundle: bundle
    ) }
    static func databricksCLICommandFailed(_ detail: String) -> String { String(
        localized: "Databricks CLI authentication failed: \(detail)",
        bundle: bundle
    ) }
    static var databricksCLICommandFailedWithoutDetail: String { String(
        localized: "Databricks CLI authentication failed.",
        bundle: bundle
    ) }
    static var databricksCLIInvalidProfilesResponse: String { String(
        localized: "Databricks CLI returned an invalid profiles response.",
        bundle: bundle
    ) }
    static var databricksProfileRequired: String { String(localized: "Select a Databricks CLI profile.", bundle: bundle) }
    static var databricksWorkspaceURLInvalid: String { String(
        localized: "Enter a valid HTTPS Databricks workspace root URL.",
        bundle: bundle
    ) }
    static var databricksWorkspaceURL: String { String(localized: "Databricks Workspace URL", bundle: bundle) }
    static var databricksWorkspaceURLDescription: String { String(
        localized: "Enter the HTTPS URL of the workspace used by Codex.",
        bundle: bundle
    ) }
    static var databricksWorkspaceURLPlaceholder: String { String(
        localized: "https://your-workspace.cloud.databricks.com",
        bundle: bundle
    ) }
    static var createNewDatabricksProfile: String { String(localized: "Create New Profile", bundle: bundle) }
    static var signInWithDatabricks: String { String(localized: "Sign in with Databricks", bundle: bundle) }
    static var databricksWorkspaceID: String { String(localized: "Databricks Workspace ID", bundle: bundle) }
    static var workspaceIDUnavailableFromProfile: String { String(
        localized: "Workspace ID unavailable from profile",
        bundle: bundle
    ) }
    static var codexConfiguration: String { String(localized: "Codex Configuration", bundle: bundle) }
    static func codexConfigurationUpdateFailed(_ detail: String) -> String { String(
        localized: "Could not update the Codex configuration: \(detail)",
        bundle: bundle
    ) }
    static var databricksConfigured: String { String(localized: "Codex is configured for Databricks", bundle: bundle) }
    static var codexAccountConfigurationNotReady: String { String(
        localized: "The selected AI account is not ready. Open Model Provider in Settings and finish its configuration.",
        bundle: bundle
    ) }
    static var databricksCodexDescription: String { String(
        localized: "Codex uses this Databricks CLI profile. Browser sign-in opens when authentication expires.",
        bundle: bundle
    ) }
    static var codexNoModels: String { String(localized: "Codex returned no available models. Try again.", bundle: bundle) }
    static var codexModelDescription: String { String(
        localized: "Models are loaded from the bundled Codex app-server.",
        bundle: bundle
    ) }
    static var reasoningEffort: String { String(localized: "Reasoning Effort", bundle: bundle) }
    static var reasoningEffortDescription: String { String(
        localized: "Controls how much reasoning Codex uses for each summary.",
        bundle: bundle
    ) }
    static var reasoningEffortNone: String { String(localized: "None", bundle: bundle) }
    static var reasoningEffortMinimal: String { String(localized: "Minimal", bundle: bundle) }
    static var reasoningEffortLow: String { String(localized: "Low", bundle: bundle) }
    static var reasoningEffortMedium: String { String(localized: "Medium", bundle: bundle) }
    static var reasoningEffortHigh: String { String(localized: "High", bundle: bundle) }
    static var reasoningEffortExtraHigh: String { String(localized: "Extra High", bundle: bundle) }
    static var reasoningEffortMax: String { String(localized: "Max", bundle: bundle) }
    static var reasoningEffortUltra: String { String(localized: "Ultra", bundle: bundle) }
    static var codexSummaryModelFooter: String { String(
        localized: "The saved model is used when available; otherwise Codex's default model is selected.",
        bundle: bundle
    ) }
    static var summaryOutput: String { String(localized: "Summary Output", bundle: bundle) }
    static var summaryDetailLevel: String { String(localized: "Detail Level", bundle: bundle) }
    static var summaryDetailLevelDescription: String { String(
        localized: "Controls how much information is included in each summary.",
        bundle: bundle
    ) }
    static var summaryDetailConcise: String { String(localized: "Concise", bundle: bundle) }
    static var summaryDetailStandard: String { String(localized: "Standard", bundle: bundle) }
    static var summaryDetailDetailed: String { String(localized: "Detailed", bundle: bundle) }
    static var summaryOutputLanguage: String { String(localized: "Output Language", bundle: bundle) }
    static var summaryOutputLanguageDescription: String { String(
        localized: "Select the language used for generated summaries.",
        bundle: bundle
    ) }
    static var llmErrorEmptyResponse: String { String(localized: "Empty response from server", bundle: bundle) }

    // MARK: - Summary

    static var runningTasks: String { String(localized: "Running Tasks", bundle: bundle) }
    static var generatingSummary: String { String(localized: "Generating summary...", bundle: bundle) }
    static var summaryGenerationFailed: String { String(localized: "Could not generate the summary.", bundle: bundle) }
    static var noSummaryYet: String { String(localized: "No summary has been generated yet.", bundle: bundle) }
    static var summaryImageUnavailable: String { String(localized: "Summary image unavailable", bundle: bundle) }
    static var openSummary: String { String(localized: "Open Summary", bundle: bundle) }
    static var generateSummary: String { String(localized: "Generate Summary", bundle: bundle) }
    static var share: String { String(localized: "Share", bundle: bundle) }
    static var shareSummary: String { String(localized: "Share Summary", bundle: bundle) }
    static var exportToGoogleDocs: String { String(localized: "Export to Google Docs", bundle: bundle) }
    static var googleDocsExportFailed: String { String(localized: "Could not export the summary to Google Docs.", bundle: bundle) }
    static var copySummaryForGoogleDocs: String { String(localized: "Copy for Google Docs", bundle: bundle) }
    static var copySummaryForSlack: String { String(localized: "Copy for Slack", bundle: bundle) }
    static var restoreAppDefaults: String { String(localized: "Restore App Defaults", bundle: bundle) }

    // MARK: - Error Messages (Audio)

    static var screenRecordingDenied: String { String(
        localized: "Screen recording access denied. Please allow it in System Settings > Privacy & Security > Screen Recording.",
        bundle: bundle
    ) }
    static var noDisplayFound: String { String(localized: "No available displays found", bundle: bundle) }
    static var invalidHardwareFormat: String { String(localized: "Invalid audio hardware format", bundle: bundle) }
    static var converterCreationFailed: String { String(localized: "Failed to create audio format converter", bundle: bundle) }
    static var microphoneDenied: String { String(
        localized: "Microphone access denied. Please allow it in System Settings > Privacy & Security > Microphone.",
        bundle: bundle
    ) }
    static var microphoneUnavailable: String { String(localized: "The selected microphone is unavailable", bundle: bundle) }
    static var echoCancellationUnavailable: String { String(localized: "Speaker echo cancellation is unavailable", bundle: bundle) }
    static var echoCancellationBypassed: String { String(
        localized: "Speaker echo cancellation became unavailable. Recording continues with raw microphone audio.",
        bundle: bundle
    ) }
    static var audioInput: String { String(localized: "Audio Input", bundle: bundle) }
    static var adjustMicrophoneInputVolume: String {
        String(localized: "Adjust Microphone Input Volume", bundle: bundle)
    }

    static var builtInMicrophoneInputVolume: String {
        String(localized: "Built-in Microphone Input Volume", bundle: bundle)
    }

    static var builtInMicrophoneInputVolumeDescription: String { String(
        localized: "Use a higher input volume in large meeting rooms. This changes the input volume for all of macOS.",
        bundle: bundle
    ) }

    static var inputVolumeUnavailable: String {
        String(localized: "Input volume cannot be changed from Dahlia on this Mac.", bundle: bundle)
    }

    static var inputVolumeUpdateFailed: String {
        String(localized: "Could not change the input volume.", bundle: bundle)
    }

    static var openSoundSettings: String { String(localized: "Open Sound Settings", bundle: bundle) }
    static var soundSettingsOpenFailed: String {
        String(localized: "Could not open Sound settings.", bundle: bundle)
    }

    static var externalMicrophoneEchoCancellation: String { String(
        localized: "Use Echo Cancellation with External Microphones",
        bundle: bundle
    ) }
    static var externalMicrophoneEchoCancellationDescription: String { String(
        localized: "Enable this when an external microphone can pick up audio from speakers.",
        bundle: bundle
    ) }
    static var builtInMicrophoneEchoCancellationDescription: String { String(
        localized: "Echo cancellation is always enabled for the built-in microphone, regardless of this setting.",
        bundle: bundle
    ) }
    static var diagnosticAudioOutputUnavailable: String { String(localized: "Could not create temporary diagnostic audio", bundle: bundle) }
    static var noAudioSourceSelected: String { String(localized: "Select at least one audio source", bundle: bundle) }

    // MARK: - Debug

    static var debug: String { String(localized: "Debug", bundle: bundle) }
    static var audioRecognitionTest: String { String(localized: "Microphone & Speech Recognition Test", bundle: bundle) }
    static var audioRecognitionTestDescription: String { String(
        localized: "Test microphone input and speech recognition without creating a recording.",
        bundle: bundle
    ) }
    static var screenCaptureRawDescription: String { String(
        localized: "Captures raw microphone PCM through ScreenCaptureKit without opening AVAudioEngine device I/O.",
        bundle: bundle
    ) }
    static var screenCaptureAutomaticDescription: String { String(
        localized: """
        The test uses ScreenCaptureKit raw input and automatically enables echo cancellation for the built-in \
        microphone or when enabled for external microphones in Transcription settings.
        """,
        bundle: bundle
    ) }
    static var screenCaptureEchoCancellationDescription: String { String(
        localized: """
        Captures raw microphone PCM and system audio through ScreenCaptureKit, then uses the system audio as the \
        WebRTC AEC3 reference to remove speaker echo.
        """,
        bundle: bundle
    ) }
    static var screenCaptureRawFallbackDescription: String { String(
        localized: "Echo cancellation became unavailable, so the test is continuing with raw microphone audio.",
        bundle: bundle
    ) }
    static var openAudioRecognitionTest: String { String(localized: "Open Test…", bundle: bundle) }
    static var audioProcessActivityMonitor: String { String(localized: "Audio Process Activity Monitor", bundle: bundle) }
    static var audioProcessActivityMonitorDescription: String { String(
        localized: "Logs CoreAudio process input and output activity for diagnosing meeting detection.",
        bundle: bundle
    ) }
    static var startAudioProcessActivityMonitor: String { String(localized: "Start Monitoring", bundle: bundle) }
    static var stopAudioProcessActivityMonitor: String { String(localized: "Stop Monitoring", bundle: bundle) }
    static var applicationLogs: String { String(localized: "Application Logs", bundle: bundle) }
    static var openApplicationLogs: String { String(localized: "Open Logs…", bundle: bundle) }
    static var applicationLogsDescription: String { String(
        localized: "View Dahlia logs from the current app session. Private values remain redacted.",
        bundle: bundle
    ) }
    static var applicationLogsUnavailable: String { String(localized: "Logs Unavailable", bundle: bundle) }
    static var noApplicationLogs: String { String(localized: "No Logs", bundle: bundle) }
    static var noApplicationLogsDescription: String { String(
        localized: "New logs from this app session appear here automatically.",
        bundle: bundle
    ) }
    static var searchApplicationLogs: String { String(localized: "Search logs…", bundle: bundle) }
    static var refreshApplicationLogs: String { String(localized: "Refresh Logs", bundle: bundle) }
    static var followLatestApplicationLogs: String { String(localized: "Follow Latest Logs", bundle: bundle) }
    static var copyDisplayedLogs: String { String(localized: "Copy Displayed Logs", bundle: bundle) }
    static var microphoneCaptureLog: String { String(localized: "Microphone Capture Log", bundle: bundle) }
    static var microphoneCaptureLogDescription: String { String(
        localized: "Shows the startup sequence for the latest audio test or recording. Diagnostic tests may store temporary comparison audio.",
        bundle: bundle
    ) }
    static var microphoneCaptureRecording: String { String(localized: "App Recording", bundle: bundle) }
    static var microphoneCaptureAudioTest: String { String(localized: "Audio Test", bundle: bundle) }

    static func microphoneCaptureStage(_ stage: MicrophoneCaptureDiagnosticStage) -> String {
        String(localized: String.LocalizationValue(stage.rawValue), bundle: bundle)
    }

    static var startAudioRecognitionTest: String { String(localized: "Start Test", bundle: bundle) }
    static var stopAudioRecognitionTest: String { String(localized: "Stop Test", bundle: bundle) }
    static var stopRecordingBeforeAudioTest: String { String(
        localized: "Stop the current recording before starting an audio test.",
        bundle: bundle
    ) }
    static var audioRecognitionTestStatus: String { String(localized: "Test Status", bundle: bundle) }
    static var inputLevel: String { String(localized: "Input Level", bundle: bundle) }
    static var rawInputLevel: String { String(localized: "Raw Input Level", bundle: bundle) }
    static var processedInputLevel: String { String(localized: "Processed Input Level", bundle: bundle) }
    static var referenceInputLevel: String { String(localized: "System Audio Reference Level", bundle: bundle) }
    static var audioBuffers: String { String(localized: "Audio Buffers", bundle: bundle) }
    static var referenceAudioBuffers: String { String(localized: "Reference Audio Buffers", bundle: bundle) }
    static func inputChannel(_ channel: Int) -> String { String(localized: "Input Channel \(channel)", bundle: bundle) }
    static var hardwareFormat: String { String(localized: "Hardware Format", bundle: bundle) }
    static var inputFormat: String { String(localized: "Input Format", bundle: bundle) }
    static var recognitionFormat: String { String(localized: "Recognition Format", bundle: bundle) }
    static var processingLatency: String { String(localized: "Processing Latency", bundle: bundle) }
    static var echoCancellationDelay: String { String(localized: "Estimated Echo Delay", bundle: bundle) }
    static var echoCancellationERLE: String { String(localized: "Echo Reduction (ERLE)", bundle: bundle) }
    static var residualEchoLikelihood: String { String(localized: "Residual Echo Likelihood", bundle: bundle) }
    static var streamDelayHint: String { String(localized: "AEC Stream Delay Hint", bundle: bundle) }
    static var presentationTimeDelta: String { String(localized: "Capture − Reference PTS", bundle: bundle) }
    static var referenceCallbackLatency: String { String(localized: "Reference Callback Latency", bundle: bundle) }
    static var captureCallbackLatency: String { String(localized: "Capture Callback Latency", bundle: bundle) }
    static var renderFrameLead: String { String(localized: "Render Frame Lead", bundle: bundle) }
    static var referenceAudioFrames: String { String(localized: "Reference Audio Frames", bundle: bundle) }
    static var captureAudioFrames: String { String(localized: "Capture Audio Frames", bundle: bundle) }
    static var captureWithoutReferenceFrames: String { String(
        localized: "Capture Frames Without Aligned Reference",
        bundle: bundle
    ) }
    static var notAvailable: String { String(localized: "Not available", bundle: bundle) }
    static var diagnosticAudioOutput: String { String(localized: "Diagnostic Audio Output", bundle: bundle) }
    static var temporaryAudioFolder: String { String(localized: "Temporary Audio Folder", bundle: bundle) }
    static var showTemporaryAudioInFinder: String { String(localized: "Show Temporary Audio in Finder", bundle: bundle) }
    static var rawDiagnosticAudioOutputDescription: String { String(
        localized: "Raw microphone audio is stored as a temporary CAF file and is not added to recordings.",
        bundle: bundle
    ) }
    static var echoCancellationDiagnosticAudioOutputDescription: String { String(
        localized: """
        Raw, system-audio reference, and processed CAF files are stored in a temporary folder for comparison and are \
        not added to recordings.
        """,
        bundle: bundle
    ) }
    static var recognizedText: String { String(localized: "Recognized Text", bundle: bundle) }
    static var speakIntoSelectedMicrophone: String { String(localized: "Speak into the selected microphone.", bundle: bundle) }
    static var preparingAudioRecognitionTest: String { String(localized: "Preparing speech recognition…", bundle: bundle) }
    static var audioRecognitionTestListening: String { String(localized: "Listening", bundle: bundle) }
    static var audioRecognitionTestStopped: String { String(localized: "Stopped", bundle: bundle) }

    // MARK: - Error Messages (ViewModel)

    static var speechRecognitionUnavailable: String { String(localized: "Speech recognition is not available on this Mac", bundle: bundle) }
    static func speechPreparationFailed(_ error: String) -> String { String(
        localized: "Failed to prepare speech recognition: \(error)",
        bundle: bundle
    ) }
    static func languageChangeFailed(_ error: String) -> String { String(localized: "Failed to change language: \(error)", bundle: bundle) }
    static var speechRecognitionNotReady: String { String(localized: "Speech recognition is not ready", bundle: bundle) }
    static var systemAudioCaptureStopped: String { String(localized: "System audio capture stopped", bundle: bundle) }
    static var microphoneCaptureStopped: String { String(localized: "Microphone capture stopped", bundle: bundle) }
    static var recording: String { String(localized: "Recording", bundle: bundle) }
    static var automaticRecordingStop: String { String(localized: "Automatic Recording Stop", bundle: bundle) }
    static var automaticMeetingEndRecordingStop: String { String(
        localized: "Automatically Stop Recording When the Meeting Ends",
        bundle: bundle
    ) }
    static var automaticMeetingEndRecordingStopDescription: String { String(
        localized: """
        Stop and save after both recording and supported meeting-app activity have lasted at least 30 seconds. \
        Browser activity also requires a recognized meeting window. In-person meetings are not detected.
        """,
        bundle: bundle
    ) }
    static var recordingCommandHint: String { String(
        localized: "Starts or stops recording for the selected meeting.",
        bundle: bundle
    ) }
    static var meetingContent: String { String(localized: "Meeting Content", bundle: bundle) }

    // MARK: - Sidebar Footer

    static var switchVault: String { String(localized: "Switch Vault", bundle: bundle) }
    static var mcpSettings: String { String(localized: "MCP Settings", bundle: bundle) }
    static var manageVaults: String { String(localized: "Manage Vaults...", bundle: bundle) }
    static var manageProjects: String { String(localized: "Manage Projects...", bundle: bundle) }
    static var settings: String { String(localized: "Settings", bundle: bundle) }
    static var help: String { String(localized: "Help", bundle: bundle) }
    static var feedback: String { String(localized: "Feedback", bundle: bundle) }

    // MARK: - Menu Bar

    static var menuBarStartRecording: String { String(localized: "Start Recording", bundle: bundle) }
    static var menuBarStopRecording: String { String(localized: "Stop Recording", bundle: bundle) }
    static var menuBarOpenDahlia: String { String(localized: "Open Dahlia", bundle: bundle) }
    static var menuBarShowLiveSubtitles: String { String(localized: "Live Subtitles", bundle: bundle) }
    static var settingsMenuItem: String { String(localized: "Settings...", bundle: bundle) }
    static var menuBarQuitDahlia: String { String(localized: "Quit Dahlia", bundle: bundle) }
    static var menuBarCalendar: String { String(localized: "Menu Bar Calendar", bundle: bundle) }
    static var menuBarCalendarDescription: String { String(
        localized: "Choose which event details appear in the menu bar. Calendar selection and event filters above are shared.",
        bundle: bundle
    ) }
    static var menuBarCalendarDisplay: String { String(localized: "Show today's events", bundle: bundle) }
    static var menuBarCalendarDisplayDescription: String { String(
        localized: "Show ongoing and upcoming events in the menu bar menu.",
        bundle: bundle
    ) }
    static var menuBarCalendarEventTitle: String { String(localized: "Event title", bundle: bundle) }
    static var menuBarCalendarEventTitleDescription: String { String(
        localized: "Show the current or next event title in the menu bar.",
        bundle: bundle
    ) }
    static var menuBarCalendarCountdown: String { String(localized: "Time remaining", bundle: bundle) }
    static var menuBarCalendarCountdownDescription: String { String(
        localized: "Show the time until the event starts or ends.",
        bundle: bundle
    ) }
    static var meetingLinkApplications: String { String(localized: "Meeting Link Apps", bundle: bundle) }
    static var meetingLinkApplicationsDescription: String { String(
        localized: "Choose the default app Dahlia uses for meeting links. Service overrides fall back to this setting; if an app is unavailable, Dahlia uses the default web browser.",
        bundle: bundle
    ) }
    static var meetingLinkServiceOverrides: String { String(localized: "Service Overrides", bundle: bundle) }
    static var meetingLinkServiceOverridesDescription: String { String(
        localized: "Override the default only for selected meeting services.",
        bundle: bundle
    ) }
    static var allMeetingLinks: String { String(localized: "All meeting links", bundle: bundle) }
    static var useAllMeetingLinksSetting: String { String(localized: "Use all meeting links setting", bundle: bundle) }
    static var defaultWebBrowser: String { String(localized: "Default web browser", bundle: bundle) }
    static var loadingMeetingLinkApplications: String { String(localized: "Finding installed apps…", bundle: bundle) }
    static func selectedApplicationUnavailable(_ bundleIdentifier: String) -> String {
        String(
            format: String(localized: "Selected app unavailable (%@)", bundle: bundle),
            locale: .current,
            bundleIdentifier
        )
    }

    static var googleMeet: String { String(localized: "Google Meet", bundle: bundle) }
    static var zoom: String { String(localized: "Zoom", bundle: bundle) }
    static var microsoftTeams: String { String(localized: "Microsoft Teams", bundle: bundle) }
    static var slack: String { String(localized: "Slack", bundle: bundle) }
    static var menuBarNoMoreEventsToday: String { String(localized: "No more events today", bundle: bundle) }
    static var menuBarNoEvents: String { String(localized: "No events", bundle: bundle) }
    static var menuBarOpenCalendarSettings: String { String(localized: "Open Calendar Settings", bundle: bundle) }
    static var menuBarInProgress: String { String(localized: "In progress", bundle: bundle) }
    static var menuBarStartingSoon: String { String(localized: "Starting soon", bundle: bundle) }
    static var menuBarEndingSoon: String { String(localized: "Ending soon", bundle: bundle) }

    static func menuBarStartsIn(_ duration: String) -> String {
        String(localized: "Starts in \(duration)", bundle: bundle)
    }

    static func menuBarEndsIn(_ duration: String) -> String {
        String(localized: "Ends in \(duration)", bundle: bundle)
    }

    static func menuBarHoursAndMinutes(_ hours: Int, _ minutes: Int) -> String {
        String(localized: "\(hours) hr \(minutes) min", bundle: bundle)
    }

    static func menuBarHours(_ hours: Int) -> String {
        String(localized: "\(hours) hr", bundle: bundle)
    }

    static func menuBarMinutes(_ minutes: Int) -> String {
        String(localized: "\(minutes) min", bundle: bundle)
    }

    static var menuBarJoinMeetingWithRecording: String { String(localized: "Join Meeting (with recording)", bundle: bundle) }
    static var menuBarJoinMeeting: String { String(localized: "Join Meeting", bundle: bundle) }
    static var menuBarShowEventInCalendar: String { String(localized: "Show Event in Calendar", bundle: bundle) }
    static var calendarAttending: String { String(localized: "Attending", bundle: bundle) }

    // MARK: - Meeting Detection

    static var meetingNotifications: String { String(localized: "Meeting Notifications", bundle: bundle) }
    static var meetingNotification: String { String(localized: "Meeting Notification", bundle: bundle) }
    static var meetingNotificationsDescription: String { String(
        localized: "Notify me about upcoming or detected meetings.",
        bundle: bundle
    ) }
    static var notificationPresentation: String { String(localized: "Notification Style", bundle: bundle) }
    static var notificationPresentationDescription: String { String(
        localized: "Choose where meeting notifications appear.",
        bundle: bundle
    ) }
    static var prominentPopup: String { String(localized: "Prominent Popup", bundle: bundle) }
    static var macOSNotification: String { String(localized: "macOS Notification", bundle: bundle) }
    static var notificationConditions: String { String(localized: "Notification Conditions", bundle: bundle) }
    static var notificationConditionsDescription: String { String(
        localized: "Choose when Dahlia sends a meeting notification.",
        bundle: bundle
    ) }
    static var microphoneActivityNotification: String { String(localized: "Meeting app microphone activity", bundle: bundle) }
    static var calendarEventNotification: String { String(localized: "One minute before calendar events", bundle: bundle) }
    static var calendarEventStartsInOneMinute: String { String(localized: "This event starts in one minute.", bundle: bundle) }
    static var joinAndStartRecording: String { String(localized: "Join and Start Recording", bundle: bundle) }
    static var startTranscription: String { String(localized: "Start Transcription", bundle: bundle) }
    static var meetingDetected: String { String(localized: "Meeting detected", bundle: bundle) }
    static func meetingDetectedSubtitle(_ appName: String) -> String { String(
        localized: "Meeting detected in \(appName)",
        bundle: bundle
    ) }
    static var noScreenshotsYet: String { String(localized: "No screenshots yet.", bundle: bundle) }

    // MARK: - Codex Chat

    static var chat: String { String(localized: "Chat", bundle: bundle) }
    static var newChat: String { String(localized: "New chat", bundle: bundle) }
    static var chatHistory: String { String(localized: "Chat history", bundle: bundle) }
    static var recentChats: String { String(localized: "Recent chats", bundle: bundle) }
    static var noRecentChats: String { String(localized: "No recent chats", bundle: bundle) }
    static var loadMore: String { String(localized: "Load more", bundle: bundle) }
    static var popOutChat: String { String(localized: "Open chat in a new window", bundle: bundle) }
    static var hideChat: String { String(localized: "Hide chat", bundle: bundle) }
    static var showChat: String { String(localized: "Show chat", bundle: bundle) }
    static var shown: String { String(localized: "Shown", bundle: bundle) }
    static var hidden: String { String(localized: "Hidden", bundle: bundle) }
    static var sendMessage: String { String(localized: "Send message", bundle: bundle) }
    static var stopGenerating: String { String(localized: "Stop generating", bundle: bundle) }
    static var chatThinking: String { String(localized: "Thinking", bundle: bundle) }
    static var messageCodex: String { String(localized: "Message Codex", bundle: bundle) }
    static var addToChat: String { String(localized: "Add to chat", bundle: bundle) }
    static var selectModel: String { String(localized: "Select model", bundle: bundle) }
    static var chatImage: String { String(localized: "Image", bundle: bundle) }
    static var attachChatImages: String { String(localized: "Attach images", bundle: bundle) }
    static var chatAttachedImage: String { String(localized: "Attached image", bundle: bundle) }
    static var chatAttachedImages: String { String(localized: "Attached images", bundle: bundle) }
    static var chatImageUnavailable: String { String(localized: "Image unavailable", bundle: bundle) }
    static var removeChatAttachedImage: String { String(localized: "Remove attached image", bundle: bundle) }
    static var chatPreparingImages: String { String(localized: "Preparing images…", bundle: bundle) }
    static var chatModelDoesNotSupportImages: String {
        String(localized: "The selected model does not support images. Choose another model or remove the images.", bundle: bundle)
    }

    static func chatImageLimitReached(_ count: Int) -> String {
        String(localized: "You can attach up to \(count) images.", bundle: bundle)
    }

    static func chatImagesUnavailable(_ count: Int) -> String {
        String(localized: "Could not attach \(count) image(s).", bundle: bundle)
    }

    static var chatLiveMode: String { String(localized: "Live mode", bundle: bundle) }
    static var enableChatLiveMode: String { String(localized: "Turn on live mode", bundle: bundle) }
    static var disableChatLiveMode: String { String(localized: "Turn off live mode", bundle: bundle) }
    static var chatLiveModeOn: String { String(localized: "Live mode on", bundle: bundle) }
    static var chatLiveModeInitialPrompt: String {
        String(
            localized: """
            I'll send you the live transcript of this meeting. \
            You don't need to respond to every transcript update. \
            Support me when needed.
            """,
            bundle: bundle
        )
    }

    static var chatLiveModeSummarizeShortcut: String {
        String(localized: "Summarize the discussion so far.", bundle: bundle)
    }

    static var chatLiveModeExplainShortcut: String {
        String(localized: "Explain what I just missed.", bundle: bundle)
    }

    static var chatLiveModeHistoryShortcut: String {
        String(localized: "Review our past conversations.", bundle: bundle)
    }

    static var chatLiveTranscriptBacklogTruncated: String {
        String(localized: "Some older live transcript was skipped because the chat backlog was too large.", bundle: bundle)
    }

    static var chatApprovalCommandTitle: String {
        String(localized: "The assistant wants to run a command.", bundle: bundle)
    }

    static var chatApprovalFileChangeTitle: String {
        String(localized: "The assistant wants to change files.", bundle: bundle)
    }

    static var chatApprovalMCPToolTitle: String {
        String(localized: "The assistant wants to change Dahlia data.", bundle: bundle)
    }

    static var chatApprovalAllowOnce: String { String(localized: "Allow once", bundle: bundle) }
    static var chatApprovalAllowSameFiles: String {
        String(localized: "Allow changes to the same files in this chat", bundle: bundle)
    }

    static var chatApprovalAllowSimilarCommands: String { String(localized: "Allow similar commands", bundle: bundle) }
    static var chatApprovalSimilarCommandScope: String {
        String(localized: "Commands that will be allowed without asking again", bundle: bundle)
    }

    static func chatApprovalAddFile(_ path: String) -> String {
        String(localized: "Add file: \(path)", bundle: bundle)
    }

    static func chatApprovalDeleteFile(_ path: String) -> String {
        String(localized: "Delete file: \(path)", bundle: bundle)
    }

    static func chatApprovalUpdateFile(_ path: String) -> String {
        String(localized: "Update file: \(path)", bundle: bundle)
    }

    static func chatApprovalMoveFile(_ path: String, to destination: String) -> String {
        String(localized: "Move file: \(path) → \(destination)", bundle: bundle)
    }

    static var chatApprovalDeny: String { String(localized: "Deny", bundle: bundle) }
    static var chatApprovalMethod: String { String(localized: "Approval method", bundle: bundle) }
    static var chatChangePermissions: String { String(localized: "Change permissions", bundle: bundle) }
    static var chatApprovalAsk: String { String(localized: "Ask for approval", bundle: bundle) }
    static var chatApprovalAskDescription: String { String(
        localized: "Always ask before editing files outside the workspace or using the internet.",
        bundle: bundle
    ) }
    static var chatApprovalAutoReview: String { String(localized: "Review approvals", bundle: bundle) }
    static var chatApprovalAutoReviewDescription: String { String(
        localized: "Ask only when an operation is detected as potentially unsafe.",
        bundle: bundle
    ) }
    static var chatApprovalAutoReviewRequiresSubscription: String {
        String(localized: "Available with a ChatGPT subscription only.", bundle: bundle)
    }

    static var chatApprovalFullAccess: String { String(localized: "Full access", bundle: bundle) }
    static var chatApprovalFullAccessDescription: String { String(
        localized: "Allow unrestricted access to the internet and all files on this Mac.",
        bundle: bundle
    ) }

    static func chatApprovalUpdateFailed(_ detail: String) -> String { String(
        localized: "Could not update the approval method: \(detail)",
        bundle: bundle
    ) }
    static var chatApprovalDetailsTooLarge: String {
        String(localized: "This request is too large to review completely, so it cannot be approved.", bundle: bundle)
    }

    static var chatApprovalUnsupportedScope: String {
        String(localized: "This request asks for permissions outside the allowed workspace and cannot be approved.", bundle: bundle)
    }

    static var openAISettings: String { String(localized: "Open Model Provider Settings", bundle: bundle) }
    static var chatModelLoading: String { String(localized: "Loading models…", bundle: bundle) }
    static var chatWindowUnavailable: String { String(localized: "This chat is no longer available.", bundle: bundle) }
    static var resize: String { String(localized: "Resize", bundle: bundle) }
    static var chatShowAll: String { String(localized: "Show all chats", bundle: bundle) }
    static var chatPresets: String { String(localized: "Presets", bundle: bundle) }
    static func chatProjectOrganizationShortcutTitle(_ days: Int) -> String {
        String(localized: "Organize meetings and Projects from the last \(days) days", bundle: bundle)
    }

    static func chatProjectOrganizationShortcutPrompt(
        days: Int,
        createdFrom: String,
        createdBefore: String
    ) -> String {
        String(
            format: String(localized: "Project organization chat shortcut prompt", bundle: bundle),
            locale: .current,
            Int64(days),
            createdFrom,
            createdBefore
        )
    }

    static var copyChatMessage: String { String(localized: "Copy message", bundle: bundle) }
    static var copyCodeBlock: String { String(localized: "Copy code", bundle: bundle) }
    static var chatReasoning: String { String(localized: "Thought process", bundle: bundle) }
    static var selected: String { String(localized: "Selected", bundle: bundle) }
    static var responsePerformance: String { String(localized: "Response performance", bundle: bundle) }
    static var meetingReferences: String { String(localized: "Meeting references", bundle: bundle) }
    static var addMeetingReference: String { String(localized: "Add meeting reference", bundle: bundle) }
    static func removeMeetingReference(_ name: String) -> String { String(
        localized: "Remove meeting reference \(name)",
        bundle: bundle
    ) }
    static var noMatchingMeetingReferences: String { String(
        localized: "No matching meetings",
        bundle: bundle
    ) }
    static var meetingUnavailable: String { String(localized: "Meeting unavailable", bundle: bundle) }
    static var showMeetingReferenceDetails: String { String(localized: "Show meeting details", bundle: bundle) }

    // MARK: - Conversation Analytics

    static var conversationAnalytics: String { String(localized: "Conversation Analytics", bundle: bundle) }
    static var conversationAnalyticsBeta: String { String(localized: "BETA", bundle: bundle) }
    static var conversationAnalyticsPending: String { String(localized: "Analysis is waiting for transcription", bundle: bundle) }
    static var conversationAnalyticsAvailableAfterTranscription: String { String(
        localized: "Conversation analytics will be available after recording and transcription finish.",
        bundle: bundle
    ) }
    static var conversationAnalyticsEmpty: String { String(
        localized: "A confirmed microphone or system-audio transcript is required.",
        bundle: bundle
    ) }
    static var conversationAnalyticsLoadFailed: String { String(localized: "Could Not Load Conversation Analytics", bundle: bundle) }
    static var conversationAnalyticsYou: String { String(localized: "You", bundle: bundle) }
    static var conversationAnalyticsOtherSide: String { String(localized: "Other Side", bundle: bundle) }
    static var conversationAnalyticsOverlap: String { String(localized: "Overlap", bundle: bundle) }
    static var conversationAnalyticsSpeakingPace: String { String(localized: "Speaking Pace", bundle: bundle) }
    static var conversationAnalyticsPaceTrend: String { String(localized: "Speaking Pace Over Time", bundle: bundle) }
    static var conversationAnalyticsPaceSeries: String { String(localized: "Pace Series", bundle: bundle) }
    static var conversationAnalyticsElapsedTime: String { String(localized: "Elapsed Time", bundle: bundle) }
    static var conversationAnalyticsPaceTrendUnavailable: String { String(
        localized: "No measurable speaking pace over time.",
        bundle: bundle
    ) }
    static var conversationAnalyticsPaceTrendExcludesUnmeasurable: String { String(
        localized: "Segments without measurable duration are excluded from the pace-over-time chart.",
        bundle: bundle
    ) }
    static var conversationAnalyticsOccupancy: String { String(localized: "Conversation Occupancy", bundle: bundle) }
    static var conversationAnalyticsOverlapRate: String { String(localized: "Overlap Rate", bundle: bundle) }
    static var conversationAnalyticsPeerPaceUnavailable: String { String(
        localized: "No comparable pace for the other side",
        bundle: bundle
    ) }

    static func conversationAnalyticsSpeakingShareSummary(_ share: String) -> String {
        String(localized: "Your speaking share is \(share)", bundle: bundle)
    }

    static func conversationAnalyticsPeerPaceComparison(_ pace: String, _ ratio: String) -> String {
        String(localized: "Other side: \(pace) chars/min · You: \(ratio)×", bundle: bundle)
    }

    static func conversationAnalyticsPaceTrendDescription(_ minutes: String) -> String {
        String(
            localized: "Calculated in \(minutes)-minute windows using merged speech intervals.",
            bundle: bundle
        )
    }

    static func conversationAnalyticsPaceSampleValue(_ start: String, _ end: String, _ pace: String) -> String {
        String(localized: "From \(start) to \(end): \(pace) chars/min", bundle: bundle)
    }

    static func conversationAnalyticsSourceFacts(_ characters: String, _ duration: String, _ segments: String) -> String {
        String(localized: "\(characters) chars · \(duration) · \(segments) segments", bundle: bundle)
    }

    static var conversationAnalyticsSpeechBalance: String { String(localized: "Speaking-Time Balance", bundle: bundle) }
    static var conversationAnalyticsMissingSourceNote: String { String(
        localized: "Only one audio source has confirmed speech.",
        bundle: bundle
    ) }
    static var conversationAnalyticsConversationFlow: String { String(localized: "Conversation Flow", bundle: bundle) }
    static var conversationAnalyticsActiveSpeech: String { String(localized: "Active Speech", bundle: bundle) }
    static var conversationAnalyticsSimultaneousSpeech: String { String(localized: "Simultaneous Speech", bundle: bundle) }
    static var conversationAnalyticsSourceDetails: String { String(localized: "Source Details", bundle: bundle) }
    static var conversationAnalyticsOverlapCount: String { String(localized: "Overlap Count", bundle: bundle) }
    static var conversationAnalyticsLongestMonologue: String { String(localized: "Longest Monologue", bundle: bundle) }
    static var charactersPerMinute: String { String(localized: "chars/min", bundle: bundle) }
    static func conversationAnalyticsMonologueDetail(_ source: String, _ start: String, _ end: String) -> String {
        String(localized: "\(source) · \(start)–\(end)", bundle: bundle)
    }

    static func conversationAnalyticsSpeechGapDescription(_ maximumGap: String) -> String {
        String(
            localized: """
            Transcript gaps up to \(maximumGap) seconds are treated as continuous speech for the timeline, speaking time, ratios, and pace; \
            short overlaps may include recognition timing differences.
            """,
            bundle: bundle
        )
    }

    static func conversationAnalyticsMonologueGapDescription(_ maximumGap: String) -> String {
        String(
            localized: """
            The longest monologue joins same-source gaps up to \(maximumGap) seconds, \
            even when the other side speaks in between.
            """,
            bundle: bundle
        )
    }

    static var conversationAnalyticsCondensedTimelineNote: String { String(
        localized: "Dense timelines are condensed for display without changing calculated metrics.",
        bundle: bundle
    ) }
    static var conversationAnalyticsLegacyTimelineNote: String { String(
        localized: "Some older transcript segments use an estimated timeline.",
        bundle: bundle
    ) }
    static var conversationAnalyticsEstimatedPaceNote: String { String(
        localized: "Speaking pace is approximate because some segments have no measurable duration.",
        bundle: bundle
    ) }
    static var conversationAnalyticsSourceCaveat: String { String(
        localized: "System audio may include multiple participants and audio from other apps.",
        bundle: bundle
    ) }
    static var conversationAnalyticsLanguageCaveat: String { String(
        localized: "Characters per minute are not directly comparable across different languages or writing systems.",
        bundle: bundle
    ) }
    static var conversationAnalyticsVoiceUnavailable: String { String(localized: "Voice Analysis Unavailable", bundle: bundle) }
    static var conversationAnalyticsVoiceUnavailableDescription: String { String(
        localized: "Voice analysis is available for meetings transcribed from retained batch audio.",
        bundle: bundle
    ) }
    static var conversationAnalyticsVoiceInsufficientDescription: String { String(
        localized: "There are not enough measured speech segments for reliable voice analysis.",
        bundle: bundle
    ) }
    static var conversationAnalyticsExcitement: String { String(localized: "Conversation Energy", bundle: bundle) }
    static var conversationAnalyticsExcitementDescription: String { String(
        localized: "Relative changes in loudness and pitch compared with each source’s baseline.",
        bundle: bundle
    ) }
    static var conversationAnalyticsExcitementUnavailable: String { String(
        localized: "No measurable conversation-energy trend.",
        bundle: bundle
    ) }
    static var conversationAnalyticsHotspots: String { String(localized: "Hotspots", bundle: bundle) }
    static var conversationAnalyticsNoHotspots: String { String(localized: "No sustained hotspots detected.", bundle: bundle) }
    static var conversationAnalyticsLoudnessOnly: String { String(
        localized: "Pitch data was limited, so some scores use loudness only.",
        bundle: bundle
    ) }
    static var conversationAnalyticsLoudnessDriver: String { String(localized: "Loudness", bundle: bundle) }
    static var conversationAnalyticsPitchDriver: String { String(localized: "Pitch", bundle: bundle) }
    static var conversationAnalyticsBothDriver: String { String(localized: "Loudness and pitch", bundle: bundle) }

    static func conversationAnalyticsVoiceSampleValue(_ start: String, _ end: String, _ value: String) -> String {
        String(localized: "From \(start) to \(end): \(value)", bundle: bundle)
    }

    static func conversationAnalyticsHotspotDetail(
        _ source: String,
        _ start: String,
        _ end: String,
        _ peakScore: String,
        _ driver: String
    ) -> String {
        String(localized: "\(source) · \(start)–\(end) · Peak \(peakScore) · \(driver)", bundle: bundle)
    }

    static var conversationAnalyticsExpression: String { String(localized: "Voice Expression", bundle: bundle) }
    static var conversationAnalyticsExpressionDescription: String { String(
        localized: "Pitch and loudness variation are evaluated independently.",
        bundle: bundle
    ) }
    static var conversationAnalyticsPitchVariation: String { String(localized: "Pitch Variation", bundle: bundle) }
    static var conversationAnalyticsLoudnessVariation: String { String(localized: "Loudness Variation", bundle: bundle) }
    static var conversationAnalyticsExpressionLowPitch: String { String(localized: "Monotone", bundle: bundle) }
    static var conversationAnalyticsExpressionLowLoudness: String { String(localized: "Steady", bundle: bundle) }
    static var conversationAnalyticsExpressionStandard: String { String(localized: "Standard", bundle: bundle) }
    static var conversationAnalyticsExpressionHighPitch: String { String(localized: "Expressive", bundle: bundle) }
    static var conversationAnalyticsExpressionHighLoudness: String { String(localized: "Dynamic", bundle: bundle) }
    static var conversationAnalyticsPitchEntrainment: String { String(localized: "Pitch Alignment", bundle: bundle) }
    static var conversationAnalyticsPitchEntrainmentDescription: String { String(
        localized: "Distance between microphone and system-audio pitch over time.",
        bundle: bundle
    ) }
    static var conversationAnalyticsPitchEntrainmentConverging: String { String(
        localized: "Voice pitch moved closer over the course of the meeting.",
        bundle: bundle
    ) }
    static var conversationAnalyticsPitchEntrainmentNeutral: String { String(
        localized: "No clear convergence in voice pitch was detected.",
        bundle: bundle
    ) }
    static var conversationAnalyticsPitchEntrainmentExperimental: String { String(
        localized: "This is an experimental indicator and does not establish rapport or psychological state.",
        bundle: bundle
    ) }
    static var conversationAnalyticsPitchEntrainmentUnavailable: String { String(
        localized: "Both audio sources need sufficient pitch measurements.",
        bundle: bundle
    ) }
    static var conversationAnalyticsSemitones: String { String(localized: "semitones", bundle: bundle) }
    static var conversationAnalyticsEnergyTrend: String { String(localized: "Voice Energy Over Time", bundle: bundle) }
    static var conversationAnalyticsEnergyTrendDescription: String { String(
        localized: "Loudness relative to each recording session’s baseline.",
        bundle: bundle
    ) }
    static var conversationAnalyticsEnergyTrendUnavailable: String { String(
        localized: "No measurable voice-energy trend.",
        bundle: bundle
    ) }
    static var conversationAnalyticsEnergyDeclining: String { String(
        localized: "Voice energy trends downward toward the end of the meeting.",
        bundle: bundle
    ) }
    static var conversationAnalyticsRelativeDecibels: String { String(localized: "Relative dB", bundle: bundle) }
    static var conversationAnalyticsVoiceCaveat: String { String(
        localized: """
        Voice indicators show relative changes from speaker and recording-session baselines; \
        they do not determine emotions or psychological state.
        """,
        bundle: bundle
    ) }
    static var conversationAnalyticsBatchFeatureCaveat: String { String(
        localized: "Voice features are measured only during batch transcription.",
        bundle: bundle
    ) }
}
