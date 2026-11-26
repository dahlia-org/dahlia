// Localized accessors intentionally remain in one namespace for discoverability and key parity.
// swiftlint:disable file_length

import Foundation

/// ローカライズ文字列への型安全なアクセスを提供する。
enum L10n { // swiftlint:disable:this type_body_length
    static var agentLearningPreviewLimit: String { String(localized: "settings.agents.learning.previewLimit", bundle: bundle) }
    static var agentMemory: String { String(localized: "settings.agents.learning.agentMemory", bundle: bundle) }
    static var agentSchedules: String { String(localized: "settings.agents.learning.agentSchedules", bundle: bundle) }
    static var agentMemoryEnabled: String { String(localized: "settings.agents.learning.agentMemoryEnabled", bundle: bundle) }
    static var skillsTabReadOnly: String { String(localized: "settings.skills.skillsTabReadOnly", bundle: bundle) }
    static var agentSkillHistory: String { String(localized: "settings.skills.agentSkillHistory", bundle: bundle) }
    static var agentSkillArchived: String { String(localized: "settings.skills.agentSkillArchived", bundle: bundle) }
    static var agentSkillUnavailable: String { String(localized: "settings.skills.agentSkillUnavailable", bundle: bundle) }
    static var skillsTabManage: String { String(localized: "settings.skills.skillsTabManage", bundle: bundle) }
    static var skillsTabCuration: String { String(localized: "settings.skills.skillsTabCuration", bundle: bundle) }
    static var settingsSkillsIntro: String { String(localized: "settings.skills.settingsSkillsIntro", bundle: bundle) }
    static var settingsMemoryIntro: String { String(localized: "settings.memory.settingsMemoryIntro", bundle: bundle) }
    static var agentSkillOptimizer: String { String(localized: "settings.agents.optimization.agentSkillOptimizer", bundle: bundle) }
    static var agentSkillReviewSection: String { String(localized: "settings.agents.optimization.agentSkillReviewSection", bundle: bundle) }
    static var agentCuratorEnabled: String { String(localized: "settings.agents.optimization.agentCuratorEnabled", bundle: bundle) }
    static var agentLegacyReviewRuns: String { String(localized: "settings.agents.optimization.agentLegacyReviewRuns", bundle: bundle) }
    static var agentReviewRuns: String { String(localized: "settings.agents.optimization.agentReviewRuns", bundle: bundle) }
    static var agentCuratorRuns: String { String(localized: "settings.agents.optimization.agentCuratorRuns", bundle: bundle) }
    static var agentOptimizerRuns: String { String(localized: "settings.agents.optimization.agentOptimizerRuns", bundle: bundle) }
    static var agentSkillActions: String { String(localized: "settings.agents.optimization.agentSkillActions", bundle: bundle) }
    static var agentSkillStartCuration: String { String(localized: "settings.agents.optimization.agentSkillStartCuration", bundle: bundle) }
    static var agentSkillStopCuration: String { String(localized: "settings.agents.optimization.agentSkillStopCuration", bundle: bundle) }
    static var agentSkillDeleteHelp: String { String(localized: "settings.agents.optimization.agentSkillDeleteHelp", bundle: bundle) }
    static func agentSkillDeleteConfirm(_ name: String) -> String {
        String(format: String(localized: "settings.agents.optimization.agentSkillDeleteConfirm", bundle: bundle), name)
    }

    static var agentOptimizerSkill: String { String(localized: "settings.agents.optimization.agentOptimizerSkill", bundle: bundle) }
    static var agentOptimizerNoSkills: String { String(localized: "settings.agents.optimization.agentOptimizerNoSkills", bundle: bundle) }
    static var agentOptimizerHelp: String { String(localized: "settings.agents.optimization.agentOptimizerHelp", bundle: bundle) }
    static var agentOptimizerStart: String { String(localized: "settings.agents.optimization.agentOptimizerStart", bundle: bundle) }
    static var agentReviewInterval: String { String(localized: "settings.agents.optimization.agentReviewInterval", bundle: bundle) }
    static var agentReviewModel: String { String(localized: "settings.agents.optimization.agentReviewModel", bundle: bundle) }
    static var agentReviewModelSelect: String { String(localized: "settings.agents.optimization.agentReviewModelSelect", bundle: bundle) }
    static var agentReviewModelHelp: String { String(localized: "settings.agents.optimization.agentReviewModelHelp", bundle: bundle) }
    static var agentReviewEffort: String { String(localized: "settings.agents.optimization.agentReviewEffort", bundle: bundle) }
    static func agentMemoryReviewEvery(_ count: Int) -> String {
        String(format: String(localized: "settings.agents.optimization.agentMemoryReviewEvery", bundle: bundle), locale: .current, count)
    }

    static func agentSkillReviewEvery(_ count: Int) -> String {
        String(format: String(localized: "settings.agents.optimization.agentSkillReviewEvery", bundle: bundle), locale: .current, count)
    }

    static func agentOptimizerPrompt(_ name: String) -> String {
        String(format: String(localized: "settings.agents.optimization.agentOptimizerPrompt", bundle: bundle), name)
    }

    static func agentOptimizerProposed(_ name: String) -> String {
        String(format: String(localized: "settings.agents.optimization.agentOptimizerProposed", bundle: bundle), name)
    }

    static func agentOptimizerNoImprovement(_ name: String) -> String {
        String(format: String(localized: "settings.agents.optimization.agentOptimizerNoImprovement", bundle: bundle), name)
    }

    static func agentOptimizerScores(baseline: Double, evolved: Double) -> String {
        String(format: String(localized: "settings.agents.optimization.agentOptimizerScores", bundle: bundle), locale: .current, baseline, evolved)
    }

    static var agentSkillCurator: String { String(localized: "settings.agents.optimization.agentSkillCurator", bundle: bundle) }
    static var agentSkillCuratorHelp: String { String(localized: "settings.agents.optimization.agentSkillCuratorHelp", bundle: bundle) }
    static var agentCuratorInterval: String { String(localized: "settings.agents.optimization.agentCuratorInterval", bundle: bundle) }
    static var agentCuratorArchiveAfter: String { String(localized: "settings.agents.optimization.agentCuratorArchiveAfter", bundle: bundle) }
    static var agentCuratorModel: String { String(localized: "settings.agents.optimization.agentCuratorModel", bundle: bundle) }
    static var agentCuratorModelAuto: String { String(localized: "settings.agents.optimization.agentCuratorModelAuto", bundle: bundle) }
    static var agentCuratorModelHelp: String { String(localized: "settings.agents.optimization.agentCuratorModelHelp", bundle: bundle) }
    static var agentCuratorEffort: String { String(localized: "settings.agents.optimization.agentCuratorEffort", bundle: bundle) }
    static var agentCuratorEffortDefault: String { String(localized: "settings.agents.optimization.agentCuratorEffortDefault", bundle: bundle) }
    static var agentCuratorEffortHelp: String { String(localized: "settings.agents.optimization.agentCuratorEffortHelp", bundle: bundle) }
    static var agentCuratorConsolidate: String { String(localized: "settings.agents.optimization.agentCuratorConsolidate", bundle: bundle) }
    static var agentCuratorConsolidateHelp: String { String(localized: "settings.agents.optimization.agentCuratorConsolidateHelp", bundle: bundle) }
    static var agentSkillReviewEnabled: String { String(localized: "settings.agents.optimization.agentSkillReviewEnabled", bundle: bundle) }
    static var agentMemoryReviewEnabled: String { String(localized: "settings.agents.optimization.agentMemoryReviewEnabled", bundle: bundle) }
    static var agentMemoryReviewHelp: String { String(localized: "settings.agents.optimization.agentMemoryReviewHelp", bundle: bundle) }
    static var agentArchivedSkills: String { String(localized: "settings.agents.optimization.agentArchivedSkills", bundle: bundle) }
    static var agentSkillRestore: String { String(localized: "settings.agents.optimization.agentSkillRestore", bundle: bundle) }
    static var agentSystemRunsMore: String { String(localized: "settings.agents.optimization.agentSystemRunsMore", bundle: bundle) }
    static var agentSystemRunsReport: String { String(localized: "settings.agents.optimization.agentSystemRunsReport", bundle: bundle) }
    static var agentSystemTaskCurator: String { String(localized: "settings.agents.optimization.agentSystemTaskCurator", bundle: bundle) }
    static var agentSystemTaskReview: String { String(localized: "settings.agents.optimization.agentSystemTaskReview", bundle: bundle) }
    static var agentSystemRunCompleted: String { String(localized: "settings.agents.optimization.agentSystemRunCompleted", bundle: bundle) }
    static var agentSystemRunFailed: String { String(localized: "settings.agents.optimization.agentSystemRunFailed", bundle: bundle) }
    static var agentSystemRunInterrupted: String { String(localized: "settings.agents.optimization.agentSystemRunInterrupted", bundle: bundle) }
    static var agentSystemRunCancelled: String { String(localized: "settings.agents.optimization.agentSystemRunCancelled", bundle: bundle) }
    static var agentSystemRunSeeded: String { String(localized: "settings.agents.optimization.agentSystemRunSeeded", bundle: bundle) }
    static var agentSystemRunRunning: String { String(localized: "settings.agents.optimization.agentSystemRunRunning", bundle: bundle) }
    static var agentCuratorSeeded: String { String(localized: "settings.agents.optimization.agentCuratorSeeded", bundle: bundle) }
    static var agentCuratorConsolidationOff: String { String(localized: "settings.agents.optimization.agentCuratorConsolidationOff", bundle: bundle) }
    static var agentCuratorNoCandidates: String { String(localized: "settings.agents.optimization.agentCuratorNoCandidates", bundle: bundle) }
    static var agentCuratorNoChange: String { String(localized: "settings.agents.optimization.agentCuratorNoChange", bundle: bundle) }
    static var agentSkillPin: String { String(localized: "settings.agents.optimization.agentSkillPin", bundle: bundle) }
    static var agentSkillPinHelp: String { String(localized: "settings.agents.optimization.agentSkillPinHelp", bundle: bundle) }
    static var agentSkillProvenanceBundled: String { String(localized: "settings.agents.optimization.agentSkillProvenanceBundled", bundle: bundle) }
    static var agentSkillProvenancePackage: String { String(localized: "settings.agents.optimization.agentSkillProvenancePackage", bundle: bundle) }
    static var agentSkillProvenanceUser: String { String(localized: "settings.agents.optimization.agentSkillProvenanceUser", bundle: bundle) }
    static var agentSkillProvenanceCurated: String { String(localized: "settings.agents.optimization.agentSkillProvenanceCurated", bundle: bundle) }
    static var agentSkillProvenanceStale: String { String(localized: "settings.agents.optimization.agentSkillProvenanceStale", bundle: bundle) }
    static var agentReviewKindMemory: String { String(localized: "settings.agents.optimization.agentReviewKindMemory", bundle: bundle) }
    static var agentReviewKindSkill: String { String(localized: "settings.agents.optimization.agentReviewKindSkill", bundle: bundle) }
    static var agentReviewKindCombined: String { String(localized: "settings.agents.optimization.agentReviewKindCombined", bundle: bundle) }
    static func agentCuratorIntervalDays(_ days: Int) -> String {
        String(format: String(localized: "settings.agents.optimization.agentCuratorIntervalDays", bundle: bundle), locale: .current, days)
    }

    static func agentCuratorDays(_ days: Int) -> String {
        String(format: String(localized: "settings.agents.optimization.agentCuratorDays", bundle: bundle), locale: .current, days)
    }

    static func agentCuratorAutoSummary(archived: Int, stale: Int, reactivated: Int) -> String {
        String(
            format: String(localized: "settings.agents.optimization.agentCuratorAutoSummary", bundle: bundle),
            locale: .current,
            archived,
            stale,
            reactivated
        )
    }

    static func agentSystemRunReviewSummary(kind: String, changes: Int) -> String {
        let label = kind == "memory" ? agentReviewKindMemory : kind == "skill" ? agentReviewKindSkill : agentReviewKindCombined
        return String(
            format: String(localized: "settings.agents.optimization.agentSystemRunReviewSummary", bundle: bundle),
            locale: .current,
            label,
            changes
        )
    }

    static var agentAlwaysOnHelp: String { String(localized: "settings.agents.alwaysOn.help", bundle: bundle) }
    static var agentAlwaysOnSources: String { String(localized: "settings.agents.alwaysOn.sources", bundle: bundle) }
    static var agentAlwaysOnNoServers: String { String(localized: "settings.agents.alwaysOn.noServers", bundle: bundle) }
    static var agentAlwaysOnEditSource: String { String(localized: "settings.agents.alwaysOn.editSource", bundle: bundle) }
    static var agentAlwaysOnAddSource: String { String(localized: "settings.agents.alwaysOn.addSource", bundle: bundle) }
    static var agentAlwaysOnChooseSource: String { String(localized: "settings.agents.alwaysOn.chooseSource", bundle: bundle) }
    static var agentAlwaysOnSuggestedMail: String { String(localized: "settings.agents.alwaysOn.suggestedMail", bundle: bundle) }
    static var agentAlwaysOnSuggestedSlack: String { String(localized: "settings.agents.alwaysOn.suggestedSlack", bundle: bundle) }
    static var agentAlwaysOnInstructionsHelp: String { String(localized: "settings.agents.alwaysOn.instructionsHelp", bundle: bundle) }
    static var agentAlwaysOnAdvanced: String { String(localized: "settings.agents.alwaysOn.advanced", bundle: bundle) }
    static var agentAlwaysOnDeleteSource: String { String(localized: "settings.agents.alwaysOn.deleteSource", bundle: bundle) }
    static var agentAlwaysOnDeleteSourceMessage: String { String(localized: "settings.agents.alwaysOn.deleteSourceMessage", bundle: bundle) }
    static var agentAlwaysOnInstructions: String { String(localized: "settings.agents.alwaysOn.instructions", bundle: bundle) }
    static var agentAlwaysOnInstructionsPlaceholder: String { String(localized: "settings.agents.alwaysOn.instructionsPlaceholder", bundle: bundle) }
    static var agentAlwaysOnInterval: String { String(localized: "settings.agents.alwaysOn.interval", bundle: bundle) }
    static func agentAlwaysOnIntervalMinutes(_ value: Int) -> String {
        String(format: String(localized: "settings.agents.alwaysOn.intervalMinutes", bundle: bundle), locale: .current, value)
    }

    static var agentCalendarSource: String { String(localized: "settings.agents.calendar.source", bundle: bundle) }
    static var agentCalendarDaily: String { String(localized: "settings.agents.calendar.daily", bundle: bundle) }
    static var agentCalendarDailyTime: String { String(localized: "settings.agents.calendar.dailyTime", bundle: bundle) }
    static var agentCalendarBeforeMeeting: String { String(localized: "settings.agents.calendar.beforeMeeting", bundle: bundle) }
    static var agentCalendarLeadHours: String { String(localized: "settings.agents.calendar.leadHours", bundle: bundle) }
    static var agentCalendarScheduleHelp: String { String(localized: "settings.agents.calendar.scheduleHelp", bundle: bundle) }
    static var agentCalendarInvalidSchedule: String { String(localized: "settings.agents.calendar.invalidSchedule", bundle: bundle) }
    static var agentCalendarDailyNote: String { String(localized: "settings.agents.calendar.dailyNote", bundle: bundle) }
    static var agentCalendarMeetingNote: String { String(localized: "settings.agents.calendar.meetingNote", bundle: bundle) }

    static func agentAlwaysOnCounts(read: Int, recorded: Int) -> String {
        String(format: String(localized: "settings.agents.alwaysOn.counts", bundle: bundle), read, recorded)
    }

    static var agentAlwaysOnAllowedSenders: String { String(localized: "settings.agents.alwaysOn.allowedSenders", bundle: bundle) }
    static var agentAlwaysOnAllowedSendersPlaceholder: String {
        String(localized: "settings.agents.alwaysOn.allowedSendersPlaceholder", bundle: bundle)
    }

    static var agentAlwaysOnRequired: String { String(localized: "settings.agents.alwaysOn.required", bundle: bundle) }
    static func agentAlwaysOnLastIntake(_ value: String) -> String {
        String(format: String(localized: "settings.agents.alwaysOn.lastIntake", bundle: bundle), locale: .current, value)
    }

    static var agentAlwaysOnNeverRead: String { String(localized: "settings.agents.alwaysOn.neverRead", bundle: bundle) }
    static var agentAlwaysOnGapDismiss: String { String(localized: "settings.agents.alwaysOn.gapDismiss", bundle: bundle) }
    static var agentAlwaysOnGap: String { String(localized: "settings.agents.alwaysOn.gap", bundle: bundle) }
    static var agentAlwaysOnEvents: String { String(localized: "settings.agents.alwaysOn.events", bundle: bundle) }
    static var agentAlwaysOnEventsEmpty: String { String(localized: "settings.agents.alwaysOn.eventsEmpty", bundle: bundle) }
    static var agentAlwaysOnEventIgnored: String { String(localized: "settings.agents.alwaysOn.eventIgnored", bundle: bundle) }
    static var agentAlwaysOnEventUnassigned: String { String(localized: "settings.agents.alwaysOn.eventUnassigned", bundle: bundle) }
    static var agentAlwaysOnEventAssigned: String { String(localized: "settings.agents.alwaysOn.eventAssigned", bundle: bundle) }
    static var agentAlwaysOnEventDelivered: String { String(localized: "settings.agents.alwaysOn.eventDelivered", bundle: bundle) }
    static var agentAlwaysOnEventProcessed: String { String(localized: "settings.agents.alwaysOn.eventProcessed", bundle: bundle) }

    static var agentBotInbox: String { String(localized: "settings.agents.alwaysOn.botInbox", bundle: bundle) }
    static var agentBotInboxEmpty: String { String(localized: "settings.agents.alwaysOn.botInboxEmpty", bundle: bundle) }
    static var agentBotKindQuestion: String { String(localized: "settings.agents.alwaysOn.botKindQuestion", bundle: bundle) }
    static var agentBotKindReport: String { String(localized: "settings.agents.alwaysOn.botKindReport", bundle: bundle) }
    static var agentBotKindSuggestion: String { String(localized: "settings.agents.alwaysOn.botKindSuggestion", bundle: bundle) }
    static var agentBotRecommended: String { String(localized: "settings.agents.alwaysOn.botRecommended", bundle: bundle) }
    static var agentBotAnswer: String { String(localized: "settings.agents.alwaysOn.botAnswer", bundle: bundle) }
    static var agentBotAnswerPlaceholder: String { String(localized: "settings.agents.alwaysOn.botAnswerPlaceholder", bundle: bundle) }
    static var agentBotAnswerSend: String { String(localized: "settings.agents.alwaysOn.botAnswerSend", bundle: bundle) }
    static var agentBotDismiss: String { String(localized: "settings.agents.alwaysOn.botDismiss", bundle: bundle) }
    static var agentBotAccept: String { String(localized: "settings.agents.alwaysOn.botAccept", bundle: bundle) }
    static var agentBotAccepted: String { String(localized: "settings.agents.alwaysOn.botAccepted", bundle: bundle) }
    static var agentBotSeen: String { String(localized: "settings.agents.alwaysOn.botSeen", bundle: bundle) }
    static var agentBotGuidancePlaceholder: String { String(localized: "settings.agents.alwaysOn.botGuidancePlaceholder", bundle: bundle) }
    static var agentBotModels: String { String(localized: "settings.agents.alwaysOn.botModels", bundle: bundle) }
    static var agentBotEffort: String { String(localized: "settings.agents.alwaysOn.botEffort", bundle: bundle) }
    static var agentBotIntakeModel: String { String(localized: "settings.agents.alwaysOn.botIntakeModel", bundle: bundle) }
    static var agentBotIntakeModelHelp: String { String(localized: "settings.agents.alwaysOn.botIntakeModelHelp", bundle: bundle) }
    static var agentBotUnattendedModel: String { String(localized: "settings.agents.alwaysOn.botUnattendedModel", bundle: bundle) }
    static var agentBotUnattendedModelHelp: String { String(localized: "settings.agents.alwaysOn.botUnattendedModelHelp", bundle: bundle) }
    static var agentBotModelDefault: String { String(localized: "settings.agents.alwaysOn.botModelDefault", bundle: bundle) }
    static var agentBotModelConversation: String { String(localized: "settings.agents.alwaysOn.botModelConversation", bundle: bundle) }
    static var agentBotSoul: String { String(localized: "settings.agents.alwaysOn.botSoul", bundle: bundle) }

    static var agentBotOpenTask: String { String(localized: "settings.agents.alwaysOn.openTask", bundle: bundle) }
    static var agentBotFinishTask: String { String(localized: "bots.finishTask", bundle: bundle) }
    static var agentBots: String { String(localized: "bots.section", bundle: bundle) }
    static var agentBotName: String { String(localized: "bots.dahliaBot", bundle: bundle) }
    static var agentBotIdle: String { String(localized: "bots.idle", bundle: bundle) }
    static func agentBotNeedsAttention(_ count: Int) -> String {
        String(format: String(localized: "bots.needsAttention", bundle: bundle), locale: .current, count)
    }

    static func agentBotNotice(_ count: Int) -> String {
        String(format: String(localized: "bots.notice", bundle: bundle), locale: .current, count)
    }

    static var agentBotRetiredReadOnly: String { String(localized: "bots.retiredReadOnly", bundle: bundle) }
    static var agentBotShowPanel: String { String(localized: "bots.showPanel", bundle: bundle) }
    static var agentBotHidePanel: String { String(localized: "bots.hidePanel", bundle: bundle) }
    static var agentBotTasks: String { String(localized: "bots.tasks", bundle: bundle) }
    static var agentBotTasksEmpty: String { String(localized: "bots.tasksEmpty", bundle: bundle) }
    static var agentBotTasksFinished: String { String(localized: "bots.tasksFinished", bundle: bundle) }
    static func agentBotTaskStatus(_ status: String) -> String {
        switch status {
        case "done": String(localized: "bots.taskDone", bundle: bundle)
        case "dismissed": String(localized: "bots.taskDismissed", bundle: bundle)
        default: String(localized: "bots.taskActive", bundle: bundle)
        }
    }

    static var agentBotSoulHelp: String { String(localized: "bots.soulHelp", bundle: bundle) }
    static var agentBotSoulEmpty: String { String(localized: "bots.soulEmpty", bundle: bundle) }
    static var agentBotShowInFinder: String { String(localized: "bots.showInFinder", bundle: bundle) }
    static var agentBotReset: String { String(localized: "bots.reset", bundle: bundle) }
    static var agentBotResetMessage: String { String(localized: "bots.resetMessage", bundle: bundle) }
    static var agentBotInboxTab: String { String(localized: "bots.inboxTab", bundle: bundle) }
    static var agentBotSettings: String { String(localized: "bots.settings", bundle: bundle) }
    static var agentBotConversation: String { String(localized: "bots.conversation", bundle: bundle) }
    static var agentBotPaused: String { String(localized: "bots.paused", bundle: bundle) }
    static var agentBotResume: String { String(localized: "bots.resume", bundle: bundle) }

    static func agentIntakeSummary(source: String, count: Int) -> String {
        String(format: String(localized: "settings.agents.alwaysOn.intakeSummary", bundle: bundle), locale: .current, source, count)
    }

    static var agentLearningDefaultHelp: String { String(localized: "settings.agents.learning.agentLearningDefaultHelp", bundle: bundle) }
    static var agentMemoryUser: String { String(localized: "settings.agents.learning.agentMemoryUser", bundle: bundle) }
    static var agentMemoryEnvironment: String { String(localized: "settings.agents.learning.agentMemoryEnvironment", bundle: bundle) }
    static var agentMemoryUserExample: String { String(localized: "settings.agents.learning.agentMemoryUserExample", bundle: bundle) }
    static var agentMemoryEnvironmentExample: String { String(localized: "settings.agents.learning.agentMemoryEnvironmentExample", bundle: bundle) }
    static var agentMemoryByUser: String { String(localized: "settings.agents.learning.agentMemoryByUser", bundle: bundle) }
    static var agentMemoryByAgent: String { String(localized: "settings.agents.learning.agentMemoryByAgent", bundle: bundle) }
    static var agentMemoryClear: String { String(localized: "settings.agents.learning.agentMemoryClear", bundle: bundle) }
    static var agentLearningApprove: String { String(localized: "settings.agents.learning.agentLearningApprove", bundle: bundle) }
    static var agentLearningDiscard: String { String(localized: "settings.agents.learning.agentLearningDiscard", bundle: bundle) }
    static var agentLearningUndo: String { String(localized: "settings.agents.learning.agentLearningUndo", bundle: bundle) }
    static var agentLearningPending: String { String(localized: "settings.agents.learning.agentLearningPending", bundle: bundle) }
    static var agentLearningApplied: String { String(localized: "settings.agents.learning.agentLearningApplied", bundle: bundle) }
    static var agentLearningClosed: String { String(localized: "settings.agents.learning.agentLearningClosed", bundle: bundle) }
    static var agentLearningUpdated: String { String(localized: "settings.agents.learning.agentLearningUpdated", bundle: bundle) }
    static var agentScheduleApproval: String { String(localized: "settings.agents.learning.agentScheduleApproval", bundle: bundle) }
    static var agentScheduleReadOnly: String { String(localized: "settings.agents.learning.agentScheduleReadOnly", bundle: bundle) }
    static var agentScheduleResultReady: String { String(localized: "settings.agents.learning.agentScheduleResultReady", bundle: bundle) }
    static var agentScheduleUnread: String { String(localized: "settings.agents.learning.agentScheduleUnread", bundle: bundle) }
    static var agentScheduleHelp: String { String(localized: "settings.agents.learning.agentScheduleHelp", bundle: bundle) }
    static var agentSchedulesEmpty: String { String(localized: "settings.agents.learning.agentSchedulesEmpty", bundle: bundle) }
    static var agentSchedulePause: String { String(localized: "settings.agents.learning.agentSchedulePause", bundle: bundle) }
    static var agentScheduleResume: String { String(localized: "settings.agents.learning.agentScheduleResume", bundle: bundle) }
    static var agentScheduleRun: String { String(localized: "settings.agents.learning.agentScheduleRun", bundle: bundle) }
    static var agentScheduleOpen: String { String(localized: "settings.agents.learning.agentScheduleOpen", bundle: bundle) }
    static var agentScheduleNotify: String { String(localized: "settings.agents.learning.agentScheduleNotify", bundle: bundle) }
    static var agentScheduleWaitingRecording: String { String(localized: "settings.agents.learning.agentScheduleWaitingRecording", bundle: bundle) }
    static var agentSkillLock: String { String(localized: "settings.agents.learning.agentSkillLock", bundle: bundle) }
    static var chatChildThread: String { String(localized: "chat.thread.child", bundle: bundle) }
    static func chatToolUseCount(_ count: Int) -> String {
        String(format: String(localized: "chat.toolUseCount", bundle: bundle), locale: .current, count)
    }

    static func chatWorkedFor(_ duration: TimeInterval?) -> String {
        guard let duration else { return String(localized: "chat.worked", bundle: bundle) }
        let elapsed = Duration.seconds(max(0, duration.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
        return String(format: String(localized: "chat.workedFor", bundle: bundle), locale: .current, elapsed)
    }

    static func chatRelatedThreadCount(_ count: Int) -> String {
        String(format: String(localized: "chat.thread.relatedCount", bundle: bundle), locale: .current, count)
    }

    static func chatActiveThreadCount(_ count: Int) -> String {
        String(format: String(localized: "chat.thread.activeCount", bundle: bundle), locale: .current, count)
    }

    static var chatRemoveThreadReference: String { String(localized: "chat.thread.removeReference", bundle: bundle) }
    static var chatAddThreadReference: String { String(localized: "chat.thread.addReference", bundle: bundle) }
    static func agentScheduleStatus(_ status: String) -> String {
        switch status {
        case "delivered": String(localized: "settings.agents.learning.delivered", bundle: bundle)
        case "silent": String(localized: "settings.agents.learning.silent", bundle: bundle)
        default: chatRunStatus(status)
        }
    }

    static func chatRunStatus(_ status: String) -> String {
        switch status {
        case "queued": String(localized: "chat.run.queued", bundle: bundle)
        case "running": chatThreadRunning
        case "waitingForUser": chatThreadWaitingForUser
        case "completed", "idle": String(localized: "chat.run.completed", bundle: bundle)
        case "interrupted": String(localized: "chat.run.interrupted", bundle: bundle)
        default: String(localized: "chat.run.failed", bundle: bundle)
        }
    }

    static var oauthCallbackLanguage: String { String(localized: "oauth.callback.language", bundle: bundle) }
    static var oauthCallbackReceived: String { String(localized: "oauth.callback.received", bundle: bundle) }
    static var oauthCallbackContinue: String { String(localized: "oauth.callback.continue", bundle: bundle) }
    static var oauthCallbackFailed: String { String(localized: "oauth.callback.failed", bundle: bundle) }
    static var oauthCallbackRetry: String { String(localized: "oauth.callback.retry", bundle: bundle) }
    static var chatResumeStateMissing: String { String(localized: "Chat resume state missing", bundle: bundle) }
    static var agentPackages: String { String(localized: "settings.agents.packages", bundle: bundle) }
    static var agentPackageCatalog: String { String(localized: "settings.agents.packageCatalog", bundle: bundle) }
    static var agentPackageSource: String { String(localized: "settings.agents.packageSource", bundle: bundle) }
    static var agentPackageInstall: String { String(localized: "settings.agents.packageInstall", bundle: bundle) }
    static var agentPackageHelp: String { String(localized: "settings.agents.packageHelp", bundle: bundle) }
    static var agentPackageChanged: String { String(localized: "settings.agents.packageChanged", bundle: bundle) }
    static var agentPackageInvalidSource: String { String(localized: "settings.agents.packageInvalidSource", bundle: bundle) }
    static var agentPackageBusy: String { String(localized: "settings.agents.packageBusy", bundle: bundle) }
    static var agentPackageFailed: String { String(localized: "settings.agents.packageFailed", bundle: bundle) }
    static var agentPackageNoVersions: String { String(localized: "settings.agents.packageNoVersions", bundle: bundle) }
    static var agentPackageErrorDetails: String { String(localized: "settings.agents.packageErrorDetails", bundle: bundle) }
    static var autoReviewPackageDescription: String { String(localized: "settings.agents.autoReview.package", bundle: bundle) }
    static var webAccessPackageDescription: String { String(localized: "settings.agents.webAccess.package", bundle: bundle) }
    static var webAccessSettings: String { String(localized: "settings.agents.webAccess.settings", bundle: bundle) }
    static var webAccessWebSearch: String { String(localized: "settings.agents.webAccess.webSearch", bundle: bundle) }
    static var webAccessWebSearchHelp: String { String(localized: "settings.agents.webAccess.webSearch.help", bundle: bundle) }
    static var webAccessAPIKeys: String { String(localized: "settings.agents.webAccess.apiKeys", bundle: bundle) }
    static var webAccessAPIKeysHelp: String { String(localized: "settings.agents.webAccess.apiKeys.help", bundle: bundle) }
    static var webAccessAPIKeyPrompt: String { String(localized: "settings.agents.webAccess.apiKey.prompt", bundle: bundle) }
    static var webAccessNodeRequired: String { String(localized: "settings.agents.webAccess.nodeRequired", bundle: bundle) }
    static var downloadingRecordingArchive: String { String(localized: "processing.downloadingArchive", bundle: bundle) }
    static var processingDataUnreadable: String { String(localized: "processing.dataUnreadable", bundle: bundle) }
    static var legacyProcessingRetryOnMac: String { String(localized: "processing.retryOnMac", bundle: bundle) }
    static var recoveredRecordings: String { String(localized: "recovery.recordings", bundle: bundle) }
    static var recoveredRecording: String { String(localized: "recovery.recording", bundle: bundle) }
    static var serverConnections: String { String(localized: "settings.serverConnections", bundle: bundle) }
    static var settingsDataAndAccounts: String { String(localized: "settings.organization.settingsDataAndAccounts", bundle: bundle) }
    static var workspaceSettings: String { String(localized: "settings.organization.workspaceSettings", bundle: bundle) }
    static var searchSettings: String { String(localized: "settings.organization.searchSettings", bundle: bundle) }
    static var settingsAccountIntro: String { String(localized: "settings.organization.settingsAccountIntro", bundle: bundle) }
    static var settingsWorkspaceManagementIntro: String { String(
        localized: "settings.organization.settingsWorkspaceManagementIntro",
        bundle: bundle
    ) }
    static var settingsAccountsIntro: String { String(localized: "settings.organization.settingsAccountsIntro", bundle: bundle) }
    static var settingsAccountSelectionDescription: String { String(
        localized: "settings.organization.settingsAccountSelectionDescription",
        bundle: bundle
    ) }
    static var settingsLoading: String { String(localized: "settings.organization.settingsLoading", bundle: bundle) }
    static var settingsApplyNextGeneration: String { String(localized: "settings.organization.settingsApplyNextGeneration", bundle: bundle) }
    static var settingsSummaryOutput: String { String(localized: "settings.organization.settingsSummaryOutput", bundle: bundle) }
    static var settingsOutputLanguageDescription: String {
        String(localized: "settings.organization.settingsOutputLanguageDescription", bundle: bundle)
    }

    static var generatedContentLanguage: String { String(localized: "settings.organization.generatedContentLanguage", bundle: bundle) }

    static var settingsLocalAnalysisLanguages: String { String(localized: "settings.organization.settingsLocalAnalysisLanguages", bundle: bundle) }
    static var settingsAnalysisLanguagesDescription: String { String(
        localized: "settings.organization.settingsAnalysisLanguagesDescription",
        bundle: bundle
    ) }
    static var settingsDuringRecording: String { String(localized: "settings.organization.settingsDuringRecording", bundle: bundle) }
    static var settingsAfterRecording: String { String(localized: "settings.organization.settingsAfterRecording", bundle: bundle) }
    static var settingsAudioStorage: String { String(localized: "settings.organization.settingsAudioStorage", bundle: bundle) }
    static var transcriptionRecoverySettings: String { String(
        localized: "settings.organization.transcriptionRecoverySettings",
        bundle: bundle
    ) }
    static var settingsAutomaticExport: String { String(localized: "settings.organization.settingsAutomaticExport", bundle: bundle) }
    static var settingsChooseSummaryPreferences: String { String(localized: "settings.organization.settingsChooseSummaryPreferences", bundle: bundle)
    }

    static var summaryStyleConciseDescription: String { String(localized: "settings.organization.summaryStyleConciseDescription", bundle: bundle) }
    static var summaryStyleStandardDescription: String { String(localized: "settings.organization.summaryStyleStandardDescription", bundle: bundle) }
    static var summaryStyleDetailedDescription: String { String(localized: "settings.organization.summaryStyleDetailedDescription", bundle: bundle) }
    static var summaryStyleEventDescription: String { String(localized: "settings.organization.summaryStyleEventDescription", bundle: bundle) }
    static var summaryStyleTimelineDescription: String { String(localized: "settings.organization.summaryStyleTimelineDescription", bundle: bundle) }
    static var macInferencePreferences: String { String(localized: "settings.preferences.macInferencePreferences", bundle: bundle) }
    static var accountPreferences: String { String(localized: "settings.preferences.accountPreferences", bundle: bundle) }
    static var accountPreferencesScope: String { String(localized: "settings.preferences.accountPreferencesScope", bundle: bundle) }
    static var accountSummaryPreferencesDescription: String { String(
        localized: "settings.preferences.accountSummaryPreferencesDescription",
        bundle: bundle
    ) }
    static var generationOverrides: String { String(localized: "For this generation only", bundle: bundle) }
    static var workspaceGenerationDefault: String { String(localized: "Workspace default", bundle: bundle) }
    static var summaryStyle: String { String(localized: "settings.preferences.summaryStyle", bundle: bundle) }
    static var recordingSettings: String { String(localized: "settings.preferences.recordingSettings", bundle: bundle) }
    static var recordingStopDetection: String { String(
        localized: "settings.preferences.recordingStopDetection",
        bundle: bundle
    ) }
    static var macTranscriptionPreferences: String { String(
        localized: "settings.preferences.macTranscriptionPreferences",
        bundle: bundle
    ) }
    static var localModelPreferencesDescription: String { String(localized: "settings.preferences.localModelPreferencesDescription", bundle: bundle) }
    static var summaryProcessingLocation: String { String(localized: "settings.preferences.summaryProcessingLocation", bundle: bundle) }
    static var serverSummaryProcessingDescription: String { String(
        localized: "settings.preferences.serverSummaryProcessingDescription",
        bundle: bundle
    ) }
    static var processingWorkflow: String { String(localized: "settings.preferences.processingWorkflow", bundle: bundle) }
    static var transcribeThenSummarize: String { String(localized: "settings.preferences.transcribeThenSummarize", bundle: bundle) }
    static var combinedTranscriptionSummary: String { String(localized: "settings.preferences.combinedTranscriptionSummary", bundle: bundle) }
    static var transcribeThenSummarizeDescription: String { String(
        localized: "settings.preferences.transcribeThenSummarizeDescription",
        bundle: bundle
    ) }
    static var combinedTranscriptionSummaryDescription: String { String(
        localized: "settings.preferences.combinedTranscriptionSummaryDescription",
        bundle: bundle
    ) }
    static var serverTranscriptionLanguageDescription: String { String(
        localized: "settings.preferences.serverTranscriptionLanguageDescription",
        bundle: bundle
    ) }
    static var appleSpeechSettingsScopeDescription: String { String(
        localized: "settings.preferences.appleSpeechSettingsScopeDescription",
        bundle: bundle
    ) }
    static var summaryModel: String { String(localized: "settings.preferences.summaryModel", bundle: bundle) }
    static var audioProcessingModel: String { String(localized: "settings.preferences.audioProcessingModel", bundle: bundle) }
    static var audioProcessingReasoningEffort: String { String(
        localized: "settings.preferences.audioProcessingReasoningEffort",
        bundle: bundle
    ) }
    static var summaryReasoningEffort: String { String(localized: "settings.preferences.summaryReasoningEffort", bundle: bundle) }
    static var automaticModelPreference: String { String(localized: "settings.preferences.automaticModelPreference", bundle: bundle) }
    static var unavailableModelPreference: String { String(localized: "settings.preferences.unavailableModelPreference", bundle: bundle) }
    static var checkModelPreference: String { String(localized: "settings.preferences.checkModelPreference", bundle: bundle) }
    static var transcriptionAndSummary: String { String(localized: "settings.processing.title", bundle: bundle) }
    static var processingLocation: String { String(localized: "settings.processing.location", bundle: bundle) }
    static var localProcessing: String { String(localized: "settings.processing.local", bundle: bundle) }
    static var thisMac: String { String(localized: "settings.processing.thisMac", bundle: bundle) }
    static var thisMacSettingsDescription: String { String(localized: "settings.processing.thisMacDescription", bundle: bundle) }
    static var transcriptFullTranscriptionUnavailable: String { String(localized: "transcript.fullTranscriptionUnavailable", bundle: bundle) }
    static var serverSearchKind: String { String(localized: "search.server.kind", bundle: bundle) }
    static var serverSearchAllKinds: String { String(localized: "search.server.allKinds", bundle: bundle) }
    static var serverSummaryMethod: String { String(localized: "serverSummaryMethod", bundle: bundle) }
    static var serverSummaryAudio: String { String(localized: "serverSummaryAudio", bundle: bundle) }
    static var serverSummaryTranscript: String { String(localized: "serverSummaryTranscript", bundle: bundle) }
    static var serverSummaryAccountDefault: String { String(localized: "serverSummaryAccountDefault", bundle: bundle) }
    static var serverSummaryChooseModel: String { String(localized: "serverSummaryChooseModel", bundle: bundle) }
    static var serverSummaryNoModels: String { String(localized: "serverSummaryNoModels", bundle: bundle) }
    static var serverSummaryReloadModels: String { String(localized: "serverSummaryReloadModels", bundle: bundle) }
    static var serverSummaryFailed: String { String(localized: "serverSummaryFailed", bundle: bundle) }
    static var retranscription: String { String(localized: "transcription.retranscription", bundle: bundle) }
    static var retranscriptionAppleSpeech: String { String(localized: "transcription.retranscription.appleSpeech", bundle: bundle) }
    static var localRetranscriptionPolicyDescription: String { String(localized: "transcription.retranscription.localDescription", bundle: bundle) }
    static var retranscriptionKeepsSummary: String { String(localized: "transcription.retranscription.keepsSummary", bundle: bundle) }
    static var imageAnalysis: String { String(localized: "account.settings.imageAnalysis", bundle: bundle) }
    static var imageAnalysisEnabled: String { String(localized: "account.settings.imageAnalysisEnabled", bundle: bundle) }
    static var textContentMissing: String { String(localized: "text.content.missing", bundle: bundle) }
    static var textContentLoading: String { String(localized: "text.content.loading", bundle: bundle) }
    static var textContentFailed: String { String(localized: "text.content.failed", bundle: bundle) }
    static var textContentReady: String { String(localized: "text.content.ready", bundle: bundle) }
    static var textContentStale: String { String(localized: "text.content.stale", bundle: bundle) }
    static var textContentEmpty: String { String(localized: "text.content.empty", bundle: bundle) }
    static var textContentDeleted: String { String(localized: "text.content.deleted", bundle: bundle) }
    static var textContentSearchLocal: String { String(localized: "text.content.searchLocal", bundle: bundle) }
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
    static var searchIndexStatus: String { String(localized: "Search index status", bundle: bundle) }
    static var searchQueuePending: String { String(localized: "Pending search jobs", bundle: bundle) }
    static var searchQueueProcessing: String { String(localized: "Processing search jobs", bundle: bundle) }
    static var searchIndexProgress: String { String(localized: "Indexing progress", bundle: bundle) }
    static var searchIndexDescription: String { String(localized: "Search index description", bundle: bundle) }

    static var searchDictionarySettings: String { String(localized: "Search dictionary settings", bundle: bundle) }
    static var searchDictionary: String { String(localized: "Search dictionary", bundle: bundle) }
    static var searchDictionaryIPADIC: String { String(localized: "Search dictionary IPADIC", bundle: bundle) }
    static var searchActiveDictionary: String { String(localized: "Search active dictionary", bundle: bundle) }
    static var searchNeologdDownloadDescription: String { String(localized: "Search NEologd download description", bundle: bundle) }
    static var searchNeologdUpgradeRequired: String { String(localized: "Search NEologd upgrade required", bundle: bundle) }
    static var searchNeologdUnsupported: String { String(localized: "Search NEologd unsupported", bundle: bundle) }
    static var searchNeologdDownloaded: String { String(localized: "Search NEologd downloaded", bundle: bundle) }
    static var searchNeologdDownloadOnSelection: String { String(localized: "Search NEologd download on selection", bundle: bundle) }
    static var searchNeologdDownloading: String { String(localized: "Search NEologd downloading", bundle: bundle) }
    static var searchNeologdRefresh: String { String(localized: "Search NEologd refresh", bundle: bundle) }
    static var searchNeologdCatalogUnavailable: String { String(localized: "Search NEologd catalog unavailable", bundle: bundle) }
    static var searchUserDictionary: String { String(localized: "Search user dictionary", bundle: bundle) }
    static var searchUserDictionaryNone: String { String(localized: "Search user dictionary none", bundle: bundle) }
    static var searchUserDictionaryImport: String { String(localized: "Search user dictionary import", bundle: bundle) }
    static var searchUserDictionaryRemove: String { String(localized: "Search user dictionary remove", bundle: bundle) }
    static var searchUserDictionaryDescription: String { String(localized: "Search user dictionary description", bundle: bundle) }
    static var searchDictionaryRebuildRequired: String { String(localized: "Search dictionary rebuild required", bundle: bundle) }
    static var searchDictionaryScope: String { String(localized: "Search dictionary scope", bundle: bundle) }
    static var searchNeologdLicense: String { String(localized: "Search NEologd license", bundle: bundle) }
    static var searchDictionaryDownloadFailed: String { String(localized: "Search dictionary download failed", bundle: bundle) }
    static var searchDictionaryChecksumMismatch: String { String(localized: "Search dictionary checksum mismatch", bundle: bundle) }
    static var searchDictionaryInvalid: String { String(localized: "Search dictionary invalid", bundle: bundle) }
    static var searchUserDictionaryInvalid: String { String(localized: "Search user dictionary invalid", bundle: bundle) }

    static var searchDictionaryFile: String { String(localized: "Search dictionary file", bundle: bundle) }
    static var searchDictionaryReplace: String { String(localized: "Search dictionary replace", bundle: bundle) }
    static var searchDictionaryReplaceDescription: String { String(localized: "Search dictionary replace description", bundle: bundle) }
    static var searchDictionaryClearDescription: String { String(localized: "Search dictionary clear description", bundle: bundle) }

    static var searchRanking: String { String(localized: "Search ranking", bundle: bundle) }
    static var advancedSearchSettings: String { String(localized: "Advanced search settings", bundle: bundle) }
    static var searchRankingDescription: String { String(localized: "Search ranking description", bundle: bundle) }
    static var searchRankingPreset: String { String(localized: "Ranking preset", bundle: bundle) }
    static var searchRankingPresetStandard: String { String(localized: "Ranking preset standard", bundle: bundle) }
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

    static var searchIndexPending: String { String(localized: "Search index pending", bundle: bundle) }
    static var searchIndexMetadata: String { String(localized: "Indexing meeting metadata", bundle: bundle) }
    static var searchIndexReady: String { String(localized: "Search index ready", bundle: bundle) }
    static var searchIndexFailed: String { String(localized: "Search index failed", bundle: bundle) }
    static var searchIndexErrorFormat: String { String(localized: "Search index error format", bundle: bundle) }
    static var searchImageAnalysisErrorFormat: String { String(localized: "Last image analysis error format", bundle: bundle) }
    static var searchLegacyImageAnalysisError: String { String(
        localized: "Image analysis failed. This older error has no recorded details. Check the AI settings for the account.",
        bundle: bundle
    ) }
    static var searchInvalidImageAnalysisResponse: String { String(
        localized: "The image analysis response did not match the requested format.",
        bundle: bundle
    ) }
    static var searchInvalidImageAnalysisBatch: String { String(
        localized: "Image analysis requires exactly one screenshot per request.",
        bundle: bundle
    ) }
    static var actions: String { String(localized: "Actions", bundle: bundle) }
    static var status: String { String(localized: "Status", bundle: bundle) }

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

    static var meetings: String { String(localized: "Meetings", bundle: bundle) }
    static var calendarEventOptions: String { String(localized: "Event Options", bundle: bundle) }
    static var upcomingEvents: String { String(localized: "Upcoming events", bundle: bundle) }
    static var showAll: String { String(localized: "Show all", bundle: bundle) }
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

    static var pinned: String { String(localized: "Pinned", bundle: bundle) }
    static var projectOptions: String { String(localized: "Project Options", bundle: bundle) }
    static var pinProject: String { String(localized: "Pin Project", bundle: bundle) }
    static var unpinProject: String { String(localized: "Unpin Project", bundle: bundle) }
    static var editProject: String { String(localized: "Edit Project", bundle: bundle) }
    static var noMeetingsInProject: String { String(localized: "No meetings in this project", bundle: bundle) }
    static var zoomIn: String { String(localized: "Zoom In", bundle: bundle) }
    static var zoomOut: String { String(localized: "Zoom Out", bundle: bundle) }

    static var add: String { String(localized: "Add", bundle: bundle) }
    static var save: String { String(localized: "Save", bundle: bundle) }
    static var name: String { String(localized: "Name", bundle: bundle) }
    static var updated: String { String(localized: "Updated", bundle: bundle) }
    static var ascending: String { String(localized: "Ascending", bundle: bundle) }
    static var descending: String { String(localized: "Descending", bundle: bundle) }

    static var instructions: String { String(localized: "Instructions", bundle: bundle) }
    static var context: String { String(localized: "Context", bundle: bundle) }
    static var actionItems: String { String(localized: "Action Items", bundle: bundle) }
    static var me: String { String(localized: "Me", bundle: bundle) }
    static var ask: String { String(localized: "Ask", bundle: bundle) }
    static var newProject: String { String(localized: "New Project", bundle: bundle) }
    static var createProject: String { String(localized: "Create Project", bundle: bundle) }

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
    static var workspaceRoot: String { String(localized: "Workspace Root", bundle: bundle) }
    static var projectType: String { String(localized: "Project Type", bundle: bundle) }
    static var subprojectTypeInheritanceHelp: String { String(
        localized: "This subproject inherits its Project Type from the root Project.",
        bundle: bundle
    ) }

    static func projectTypeName(_ type: ProjectType) -> String {
        switch type {
        case .customer: String(localized: "Customer", bundle: bundle)
        case .internal: String(localized: "Internal", bundle: bundle)
        case .personal: String(localized: "Personal", bundle: bundle)
        case .undefined: String(localized: "Undefined", bundle: bundle)
        }
    }

    static var location: String { String(localized: "Location", bundle: bundle) }
    static var openInObsidian: String { String(localized: "Open in Obsidian", bundle: bundle) }
    static var openInBrowser: String { String(localized: "Open in Browser", bundle: bundle) }
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
    static var searchMeetingsAndProjects: String { String(localized: "Search meetings, screenshots, projects, and chats", bundle: bundle) }
    static var screenshotSearchResults: String { String(localized: "Screenshots", bundle: bundle) }
    static var detectedText: String { String(localized: "Detected Text", bundle: bundle) }
    static var imageDescription: String { String(localized: "Image Description", bundle: bundle) }
    static var noTextDetected: String { String(localized: "No text was detected.", bundle: bundle) }
    static var imageAnalysisFailed: String { String(localized: "Image analysis failed.", bundle: bundle) }
    static var analyzingImage: String { String(localized: "Analyzing image...", bundle: bundle) }
    static var removeSearchFilter: String { String(localized: "Remove search filter", bundle: bundle) }
    static var searchUnavailable: String { String(localized: "Search unavailable", bundle: bundle) }
    static var searchIndexRecovery: String { String(localized: "search.indexRecovery", bundle: bundle) }
    static var searchRequiresWorkspace: String { String(localized: "Select a Workspace to search.", bundle: bundle) }
    static var recentMeetings: String { String(localized: "Recent Meetings", bundle: bundle) }
    static var recentProjects: String { String(localized: "Recent Projects", bundle: bundle) }
    static var searchingMeetings: String { String(localized: "Searching…", bundle: bundle) }
    static var noMeetingsMatchSearch: String { String(localized: "No meetings match your search", bundle: bundle) }
    static var adjustMeetingSearch: String { String(
        localized: "Try changing the keywords or filters.",
        bundle: bundle
    ) }

    static var clearAllSearchConditions: String { String(localized: "Clear All", bundle: bundle) }
    static var selectedMeetingOutsideResults: String { String(localized: "Selected (Outside Results)", bundle: bundle) }
    static var period: String { String(localized: "Period", bundle: bundle) }
    static var tag: String { String(localized: "Tag", bundle: bundle) }
    static var noTagsYet: String { String(localized: "No tags yet", bundle: bundle) }
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
    static var invalidSummaryOutputDestination: String { String(
        localized: "The Summary output destination must resolve inside the Workspace without symlink or file path components.",
        bundle: bundle
    ) }
    static var projectDescription: String { String(localized: "Project Description", bundle: bundle) }
    static var projectDescriptionHelp: String { String(
        localized: "The description is provided as context when generating summaries. For example, you can include project members.",
        bundle: bundle
    ) }
    static var projectDescriptionPlaceholder: String { String(localized: "Describe this project...", bundle: bundle) }
    static var saving: String { String(localized: "Saving…", bundle: bundle) }
    static var saved: String { String(localized: "Saved", bundle: bundle) }
    static var deleteProject: String { String(localized: "Delete Project", bundle: bundle) }

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
    static var projectDescriptionTooLong: String {
        String(localized: "The project description must be 20,000 characters or fewer.", bundle: bundle)
    }

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
    static var projectWorkspaceBusy: String { String(
        localized: "Another Project operation is already running for this Workspace.",
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

    static var projectManagementNoWorkspaceDescription: String { String(
        localized: "Open a workspace before managing project settings.",
        bundle: bundle
    ) }

    // MARK: - Control Panel

    static var preparingSpeechRecognition: String { String(localized: "Preparing speech recognition...", bundle: bundle) }
    static var transcription: String { String(localized: "Transcription", bundle: bundle) }
    static var stop: String { String(localized: "Stop", bundle: bundle) }
    static var startRecording: String { String(localized: "Start Recording", bundle: bundle) }
    static var stopRecording: String { String(localized: "Stop Recording", bundle: bundle) }
    static var recordingSessionAlreadyActive: String { String(localized: "A recording session is already active.", bundle: bundle) }
    static var recordingSessionNotActive: String { String(localized: "No recording session is active.", bundle: bundle) }
    static var stopTranscribing: String { String(localized: "Stop transcribing", bundle: bundle) }
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
    static var adaptiveScreenshotInterval: String { String(localized: "Adaptive Screenshot Interval", bundle: bundle) }
    static var adaptiveScreenshotIntervalDescription: String { String(
        localized: "Save a screenshot once the screen stops changing instead of checking at a fixed interval.",
        bundle: bundle
    ) }
    static var screenshotInterval: String { String(localized: "Screenshot Interval", bundle: bundle) }
    static var adaptiveScreenshotIntervalFallbackDescription: String { String(
        localized: "Dahlia checks gradual changes, and screens that mostly keep moving such as full-screen video, at this interval.",
        bundle: bundle
    ) }
    static var fixedScreenshotIntervalDescription: String { String(
        localized: "Dahlia checks the screen for changes at this interval.",
        bundle: bundle
    ) }
    static var screenshotChangeThreshold: String { String(localized: "Screenshot Change Threshold", bundle: bundle) }
    static var adaptiveScreenshotChangeThresholdDescription: String { String(
        localized: "Save a new screenshot when at least this much of the screen differs from every recent screenshot, ignoring moving areas such as camera video.",
        bundle: bundle
    ) }
    static var fixedScreenshotChangeThresholdDescription: String { String(
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
    static var selectMeetingWindowForScreenshots: String { String(localized: "Select Meeting Window Automatically", bundle: bundle) }
    static var selectMeetingWindowForScreenshotsDescription: String { String(
        localized: "When you join a meeting and start recording together, capture the window that opened the meeting link.",
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
    static var liveSubtitleOverlayToggleDescription: String { String(
        localized: "Show live subtitles when recording starts.",
        bundle: bundle
    ) }
    static var liveSubtitleOverlayDescription: String { String(
        localized: "Show speech as subtitles during recording. The final transcript is created separately after recording stops.",
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

    static var summaryVersion: String { String(localized: "Version", bundle: bundle) }
    static var summaryPromoteVersion: String { String(localized: "Make this version current", bundle: bundle) }
    static var summaryCurrentVersion: String { String(localized: "Current", bundle: bundle) }
    static var summaryReadOnlyVersion: String { String(localized: "Previous version (read-only)", bundle: bundle) }
    static var summaryGenerationDetails: String { String(localized: "Generation details", bundle: bundle) }
    static var summaryGenerationDetailsUnavailable: String {
        String(localized: "Generation details are unavailable for this version.", bundle: bundle)
    }

    static var summaryRequestedModel: String { String(localized: "Requested model", bundle: bundle) }
    static var summaryResponseModel: String { String(localized: "Response model", bundle: bundle) }
    static var summary: String { String(localized: "Summary", bundle: bundle) }
    static var notes: String { String(localized: "Notes", bundle: bundle) }
    static var documentKeepLocal: String { String(localized: "document.keepLocal", bundle: bundle) }
    static var documentRecoveryTitle: String { String(localized: "document.recovery.title", bundle: bundle) }
    static var documentRecoveryEmpty: String { String(localized: "document.recovery.empty", bundle: bundle) }
    static var documentHistoryPrevious: String { String(localized: "documentHistoryPrevious", bundle: bundle) }
    static var documentHistoryNext: String { String(localized: "documentHistoryNext", bundle: bundle) }
    static var documentHistoryFullText: String { String(localized: "documentHistoryFullText", bundle: bundle) }
    static var documentRestore: String { String(localized: "document.restore", bundle: bundle) }
    static var documentSaveFailed: String { String(localized: "documentSaveFailed", bundle: bundle) }
    static var documentUnsupportedSchema: String { String(localized: "documentUnsupportedSchema", bundle: bundle) }
    static var documentTooLarge: String { String(localized: "documentTooLarge", bundle: bundle) }
    static var documentPrivateLegacy: String { String(localized: "documentPrivateLegacy", bundle: bundle) }
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
    static var summaryGenerationSource: String { String(localized: "summary.source.title", bundle: bundle) }
    static var summarySourceTranscriptDescription: String { String(
        localized: "summary.source.transcript.description",
        bundle: bundle
    ) }
    static var summarySourceChecking: String { String(localized: "summary.source.checking", bundle: bundle) }
    static var summarySourceCheckFailed: String { String(localized: "summary.source.checkFailed", bundle: bundle) }
    static var summarySourceTranscriptUnavailable: String { String(
        localized: "summary.source.transcript.unavailable",
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
    static var exportBatchSummaryToWorkspace: String { String(
        localized: "Export Summary to Workspace",
        bundle: bundle
    ) }
    static var exportBatchSummaryToWorkspaceDescription: String { String(
        localized: "Write the generated summary and related files to the current Workspace.",
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
    static var backupDeselectAll: String { String(localized: "Deselect All Workspaces", bundle: bundle) }
    static var backupSkipWorkspace: String { String(localized: "Do Not Restore", bundle: bundle) }
    static func backupWorkspaceCount(_ count: Int) -> String {
        String(format: String(localized: "Workspaces: %d", bundle: bundle), count)
    }

    static var backupDriveRefresh: String { String(localized: "Refresh Backups", bundle: bundle) }
    static var backupDriveTitle: String { String(localized: "Google Drive Backups", bundle: bundle) }
    static var backupLocalCopies: String { String(localized: "Local Recovery Copies", bundle: bundle) }
    static var backupDriveDownload: String { String(localized: "Download for Restore", bundle: bundle) }
    static var backupDriveDescription: String { String(
        localized: """
        Lists backups in My Drive/Dahlia/Backup. Ask Dahlia AI to create and upload a backup using Google Drive MCP. Drive access here is \
        read-only; downloaded backups are verified before they appear in Local Recovery Copies.
        """,
        bundle: bundle
    ) }
    static var backupDriveAmbiguousFolder: String { String(
        localized: "Multiple Dahlia/Backup folders were found in My Drive. Resolve duplicate folder names before loading backups.",
        bundle: bundle
    ) }
    static var backupDriveDownloadFailed: String { String(
        localized: "Could not download the Google Drive backup. Check the connection and try again.",
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureTitle: String { String(localized: "Connect Google Drive for Backups", bundle: bundle) }
    static var googleDriveOAuthDisclosureOverview: String { String(
        localized: "Dahlia reads backups from My Drive/Dahlia/Backup. This connection does not upload or delete files.",
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureAccess: String { String(
        localized: "Google grants read-only access to all Drive files. Dahlia uses metadata to find Dahlia/Backup and downloads only the backups you select.",
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureUseAndStorage: String { String(
        localized: """
        Downloaded backups are stored on this Mac and validated before restore. \
        Calendar and Drive share the registered Google account’s Keychain credential.
        """,
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureExternalSharing: String { String(
        localized: "Listing and downloading send requests to Google Drive. Uploads are a separate action by Dahlia AI through your configured MCP server and follow chat approval settings.",
        bundle: bundle
    ) }
    static var googleDriveOAuthDisclosureDeletion: String { String(
        localized: """
        Disconnect stops this read connection. Remove access in your Google Account to revoke the grant. Disconnecting does not delete \
        local or Drive backups, or disconnect the separate MCP server.
        """,
        bundle: bundle
    ) }

    static var workspaceBackup: String { String(localized: "Workspace Backup", bundle: bundle) }
    static var backupLocalWorkspacesOnly: String { String(localized: "Only workspaces in the Local Account can be backed up.", bundle: bundle) }
    static var workspaceBackupDescription: String { String(
        localized: "Back up the selected workspaces together, including screenshots. Audio, external files, and account credentials are excluded.",
        bundle: bundle
    ) }
    static var backupRestoreMode: String { String(localized: "Restore Method", bundle: bundle) }
    static var backupRestoreAsNewWorkspace: String { String(localized: "Restore as a New Local Workspace", bundle: bundle) }
    static var backupOverwriteOriginalWorkspace: String { String(localized: "Overwrite the Original Local Workspace", bundle: bundle) }
    static var backupRestoreTargetUnavailable: String { String(
        localized: "Overwrite requires the original local workspace with no unprocessed recordings. Synced workspaces cannot be overwritten.",
        bundle: bundle
    ) }
    static var workspaceBackupRestoreDescription: String { String(
        localized: "Restore selected workspaces after a restart. Back up and restore each workspace independently; failed workspaces stay unchanged. Audio and external files are excluded.",
        bundle: bundle
    ) }
    static func restoredWorkspaceName(_ name: String) -> String {
        String(format: String(localized: "%@ (Restored)", bundle: bundle), name)
    }

    static var backups: String { String(localized: "Backups", bundle: bundle) }
    static var createBackup: String { String(localized: "Create Backup", bundle: bundle) }
    static var importBackup: String { String(localized: "Import Backup", bundle: bundle) }
    static var exportBackup: String { String(localized: "Export", bundle: bundle) }
    static var restoreBackup: String { String(localized: "Restore", bundle: bundle) }
    static var deleteBackup: String { String(localized: "Delete Backup", bundle: bundle) }
    static var noBackups: String { String(localized: "No Backups", bundle: bundle) }
    static var noBackupsDescription: String { String(localized: "Create a backup to preserve the selected workspace.", bundle: bundle) }
    static var backupCreated: String { String(localized: "Backup created.", bundle: bundle) }
    static var backupImported: String { String(localized: "Backup imported.", bundle: bundle) }
    static var backupExported: String { String(localized: "Backup exported.", bundle: bundle) }
    static var backupDeleted: String { String(localized: "Backup deleted.", bundle: bundle) }
    static var selectedBackupInvalid: String { String(localized: "The selected file is not a valid Dahlia backup.", bundle: bundle) }
    static var backupRestoreAlreadyPending: String { String(localized: "Another workspace restore is already pending.", bundle: bundle) }
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

    static func backupWorkspaceRestored(_ name: String, sourceWorkspaceId: UUID) -> String {
        String(format: String(localized: "%@ (Source: %@): Restored.", bundle: bundle), name, String(sourceWorkspaceId.uuidString.suffix(8)))
    }

    static func backupWorkspaceRestoreFailed(_ name: String, sourceWorkspaceId: UUID, reason: String) -> String {
        String(
            format: String(localized: "%@ (Source: %@): Restore failed — %@", bundle: bundle),
            name,
            String(sourceWorkspaceId.uuidString.suffix(8)),
            reason
        )
    }

    static func backupRestoreFailed(_ reason: String) -> String {
        String(format: String(localized: "Could not restore the workspace: %@", bundle: bundle), reason)
    }

    static var invalidBackup: String { String(localized: "Invalid backup", bundle: bundle) }
    static var beforeRestoreBackup: String { String(localized: "Created before restore", bundle: bundle) }
    static var deleteBackupConfirmation: String { String(localized: "Delete this backup?", bundle: bundle) }
    static var deleteBackupDescription: String { String(
        localized: "This backup generation will be permanently deleted. This cannot be undone.",
        bundle: bundle
    ) }
    static var restoreBackupConfirmation: String { String(localized: "Restore this backup?", bundle: bundle) }
    static var unprocessedRecordings: String { String(localized: "Unprocessed Recordings", bundle: bundle) }
    static var viewUnprocessedRecordings: String { String(localized: "Open Unprocessed Recordings", bundle: bundle) }
    static var finishRecordingBeforeOpeningAnotherWorkspace: String { String(
        localized: "Finish the current recording before opening unprocessed recordings in another workspace.",
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
    static var advanced: String { String(localized: "Advanced", bundle: bundle) }
    static var modelProvider: String { String(localized: "Model Provider", bundle: bundle) }
    static var setupDahlia: String { String(localized: "Set Up Dahlia", bundle: bundle) }

    static func version(_ version: String) -> String {
        String(format: String(localized: "Version %@", bundle: bundle), version)
    }

    static var initialSetup: String { String(localized: "Initial Setup", bundle: bundle) }
    static var setupProgress: String { String(localized: "Setup Progress", bundle: bundle) }
    static var workingLanguages: String { String(localized: "Working Languages", bundle: bundle) }
    static var setupPreparingWorkspace: String { String(localized: "setup.preparingWorkspace", bundle: bundle) }
    static var setupWorkspaceUnavailable: String { String(localized: "setup.workspaceUnavailable", bundle: bundle) }
    static var setupComplete: String { String(localized: "Setup Complete", bundle: bundle) }
    static var piSetupDescription: String { String(localized: "setup.piDescription", bundle: bundle) }
    static var piSetupSkipDescription: String { String(localized: "setup.piSkipDescription", bundle: bundle) }
    static var continueAction: String { String(localized: "Continue", bundle: bundle) }
    static var startDahlia: String { String(localized: "Start Dahlia", bundle: bundle) }
    static var workingLanguagesSetupDescription: String { String(
        localized: "Choose the languages Dahlia should recognize. Set the AI output language in Manage Workspaces.",
        bundle: bundle
    ) }
    static var recognitionAndOCRLanguages: String { String(localized: "Recognition and OCR Languages", bundle: bundle) }
    static var modelProviderSetupDescription: String { String(
        localized: "setup.modelProviderDescription",
        bundle: bundle
    ) }
    static var audioPermissionSetupDescription: String { String(
        localized: "Allow access to the audio sources Dahlia records. You can continue and grant access later.",
        bundle: bundle
    ) }
    static var calendarSetupTitle: String { String(localized: "Calendar (Optional)", bundle: bundle) }
    static var calendarSetupDescription: String { String(
        localized: "Connect a calendar to see upcoming meetings in Dahlia. You can set this up later.",
        bundle: bundle
    ) }
    static var setupCompletionDescription: String { String(
        localized: "setup.completionDescription",
        bundle: bundle
    ) }
    static var setupSummary: String { String(localized: "Setup Summary", bundle: bundle) }
    static var diagnostics: String { String(localized: "Diagnostics", bundle: bundle) }
    static var notifications: String { String(localized: "Notifications", bundle: bundle) }
    static var calendar: String { String(localized: "Calendar", bundle: bundle) }
    static var meetingLinks: String { String(localized: "Meeting Links", bundle: bundle) }

    static var workspace: String { String(localized: "Workspace", bundle: bundle) }
    static var currentWorkspace: String { String(localized: "Current Workspace", bundle: bundle) }
    static var mcp: String { String(localized: "MCP", bundle: bundle) }
    static var dahliaMCP: String { String(localized: "Dahlia MCP", bundle: bundle) }
    static var copyCommand: String { String(localized: "Copy Command", bundle: bundle) }
    static var copyMeetingID: String { String(localized: "Copy meeting_id", bundle: bundle) }
    static var copyMeetingIDHint: String { String(localized: "Copies meeting_id to the clipboard", bundle: bundle) }
    static var copyRemoveCommand: String { String(localized: "Copy Remove Command", bundle: bundle) }
    static var copied: String { String(localized: "Copied", bundle: bundle) }
    static var codexCLI: String { String(localized: "Codex CLI", bundle: bundle) }
    static var claudeCode: String { String(localized: "Claude Code", bundle: bundle) }
    static var mcpPreview: String { String(localized: "Command Preview", bundle: bundle) }
    static var mcpOtherApps: String { String(localized: "mcp.otherApps", bundle: bundle) }
    static var mcpChooseApp: String { String(localized: "mcp.chooseApp", bundle: bundle) }
    static var mcpChooseScope: String { String(localized: "mcp.chooseScope", bundle: bundle) }
    static var mcpPermissions: String { String(localized: "mcp.permissions", bundle: bundle) }
    static var mcpReadOnly: String { String(localized: "mcp.readOnly", bundle: bundle) }
    static var mcpReadWrite: String { String(localized: "mcp.readWrite", bundle: bundle) }
    static var mcpWriteExplanation: String { String(localized: "mcp.writeExplanation", bundle: bundle) }
    static var mcpCommandInstructions: String { String(localized: "mcp.commandInstructions", bundle: bundle) }
    static var mcpJSONInstructions: String { String(localized: "mcp.jsonInstructions", bundle: bundle) }
    static var mcpNoWorkspaces: String { String(localized: "mcp.noWorkspaces", bundle: bundle) }
    static var mcpScopeUnavailable: String { String(localized: "mcp.scopeUnavailable", bundle: bundle) }
    static func mcpIncludedWorkspaces(_ count: Int) -> String {
        String(format: String(localized: "mcp.includedWorkspaces", bundle: bundle), count)
    }

    static var mcpAllWorkspaces: String { String(localized: "mcp.allWorkspaces", bundle: bundle) }
    static var mcpClient: String { String(localized: "Client", bundle: bundle) }
    static var mcpAllowWriteAccess: String { String(localized: "Allow Write Access", bundle: bundle) }
    static var mcpConfigurationOutput: String { String(localized: "Configuration", bundle: bundle) }
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
    static var mcpFooter: String { String(localized: "mcp.scopeFooter", bundle: bundle) }
    static func registrationCommand(_ name: String) -> String {
        String(format: String(localized: "%@ registration command", bundle: bundle), name)
    }

    static var noWorkspaceSelected: String { String(localized: "No workspace selected", bundle: bundle) }
    static var dahliaAccount: String { String(localized: "Dahlia Account", bundle: bundle) }

    static var continueWithLocalAccount: String { String(localized: "Continue with Local Account", bundle: bundle) }
    static var orContinueWithoutSigningIn: String { String(localized: "Or continue without signing in", bundle: bundle) }
    static var dahliaServerNotConfigured: String { String(localized: "Dahlia Server is not configured.", bundle: bundle) }
    static var dahliaNotSignedIn: String { String(localized: "Not signed in", bundle: bundle) }
    static var dahliaWaitingForBrowser: String { String(localized: "Waiting for browser sign-in…", bundle: bundle) }
    static var dahliaSignIn: String { String(localized: "Sign In", bundle: bundle) }
    static var dahliaSignInDescription: String { String(
        localized: "Connect to Dahlia Cloud or an existing Dahlia Server.",
        bundle: bundle
    ) }
    static var signInToDahliaCloud: String { String(localized: "Sign In to Dahlia Cloud", bundle: bundle) }
    static var dahliaCloudComingSoon: String { String(localized: "Dahlia Cloud (Coming Soon)", bundle: bundle) }
    static var orConnectToServer: String { String(localized: "Or connect to a server", bundle: bundle) }
    static var serverURL: String { String(localized: "Server URL", bundle: bundle) }
    static var connect: String { String(localized: "Connect", bundle: bundle) }
    static var dahliaUnknownAccount: String { String(localized: "Dahlia account", bundle: bundle) }
    static var dahliaCloudBrowserCouldNotOpen: String { String(localized: "The sign-in page could not be opened.", bundle: bundle) }
    static var dahliaAuthorizationTimedOut: String { String(localized: "Dahlia sign-in timed out.", bundle: bundle) }
    static var dahliaUnexpectedResponse: String { String(localized: "Dahlia returned an unexpected response.", bundle: bundle) }
    static var dahliaCloudInvalidTokenResponse: String { String(localized: "Dahlia OAuth returned an invalid token response.", bundle: bundle) }
    static var dahliaCloudInvalidSessionResponse: String { String(localized: "Dahlia Server returned an invalid session response.", bundle: bundle) }
    static var dahliaAuthorizationDenied: String { String(localized: "Dahlia sign-in was not authorized.", bundle: bundle) }
    static var dahliaCredentialStorageFailed: String { String(
        localized: "Dahlia credentials could not be saved securely.",
        bundle: bundle
    ) }
    static var dahliaConnectionAlreadyExists: String { String(
        localized: "A Dahlia connection already exists for this server.",
        bundle: bundle
    ) }
    static var dahliaCloudAccountChanged: String { String(
        localized: "Sign in with the same Dahlia account, or add a new connection.",
        bundle: bundle
    ) }

    static func signOutDahliaConnection(_ name: String) -> String {
        String(format: String(localized: "Sign out of %@?", bundle: bundle), name)
    }

    static var databricksSignOutDescription: String { String(
        localized: "Your Workspaces will move to the Local Account and remain on this Mac. You will need to sign in again to use this account's AI models.",
        bundle: bundle
    ) }

    static func dahliaHTTPError(_ status: Int) -> String {
        String(format: String(localized: "Dahlia request failed (HTTP %lld).", bundle: bundle), status)
    }

    static var startupPreparing: String { String(localized: "Preparing to Open…", bundle: bundle) }
    static var startupRestoring: String { String(localized: "Restoring Backup…", bundle: bundle) }
    static var startupUpdating: String { String(localized: "Updating Data…", bundle: bundle) }
    static var startupWait: String { String(localized: "Dahlia will open when preparation is complete.", bundle: bundle) }
    static var startupDataWait: String { String(
        localized: "This may take some time depending on the amount of data. Please keep Dahlia open until it finishes.",
        bundle: bundle
    ) }
    static var startupFailed: String { String(localized: "Dahlia Could Not Open", bundle: bundle) }
    static var startupRestoreFailed: String { String(localized: "Backup Restore Needs Attention", bundle: bundle) }
    static var startupFailureHelp: String { String(localized: "Quit Dahlia and check the details below before opening it again.", bundle: bundle) }
    static var startupRestoreFailureHelp: String { String(
        localized: "Some data could not be restored. You can continue with the available data and review the result in Backup settings.",
        bundle: bundle
    ) }
    static var startupQuit: String { String(localized: "Quit Dahlia", bundle: bundle) }

    static var loadingWorkspaces: String { String(localized: "Loading Workspaces…", bundle: bundle) }
    static var removingWorkspace: String { String(localized: "Deleting Workspace…", bundle: bundle) }
    static var localExportFolder: String { String(localized: "Local Export Folder", bundle: bundle) }
    static var noLocalExportFolder: String { String(localized: "No local export folder", bundle: bundle) }
    static var setLocalExportFolder: String { String(localized: "Set Local Export Folder", bundle: bundle) }
    static var changeLocalExportFolder: String { String(localized: "Change Local Export Folder", bundle: bundle) }
    static var removeLocalExportFolder: String { String(localized: "Remove Local Export Folder", bundle: bundle) }

    static var lightMode: String { String(localized: "appearance.light", bundle: bundle) }
    static var darkMode: String { String(localized: "appearance.dark", bundle: bundle) }
    static var appearance: String { String(localized: "Appearance", bundle: bundle) }
    static var appearanceMenuBar: String { String(localized: "settings.appearance.menuBar", bundle: bundle) }
    static var appearanceEventDisplay: String { String(localized: "settings.appearance.eventDisplay", bundle: bundle) }
    static var display: String { String(localized: "Display", bundle: bundle) }
    static var sidebarDisplayStyle: String { String(localized: "Sidebar Display Style", bundle: bundle) }
    static var standard: String { String(localized: "Standard", bundle: bundle) }
    static var compact: String { String(localized: "Compact", bundle: bundle) }
    static var appLanguage: String { String(localized: "App Language", bundle: bundle) }
    static var textSize: String { String(localized: "appearance.textSize", bundle: bundle) }
    static var textSizeDescription: String { String(localized: "appearance.textSize.description", bundle: bundle) }
    static var textSizeFooter: String { String(localized: "appearance.textSize.footer", bundle: bundle) }
    static func textSizePoints(_ size: Int) -> String { String(localized: "appearance.textSize.points \(size)", bundle: bundle) }
    static func defaultTextSize(_ size: Int) -> String { String(localized: "appearance.textSize.default \(size)", bundle: bundle) }
    static var followSystem: String { String(localized: "Follow System", bundle: bundle) }
    static var notificationSettingsDescription: String { String(
        localized: "Choose one or both conditions. Calendar notifications use events from enabled calendar sources.",
        bundle: bundle
    ) }
    static var enableMeetingNotificationsToChooseConditions: String { String(
        localized: "Turn on meeting notifications to choose notification conditions.",
        bundle: bundle
    ) }
    static var realtimeTranscription: String { String(localized: "Real-time Transcription", bundle: bundle) }
    static var batchTranscription: String { String(localized: "Batch Transcription", bundle: bundle) }
    static var batchTranscriptionStallTimeout: String { String(localized: "No-progress Timeout", bundle: bundle) }
    static var batchTranscriptionStallTimeoutDescription: String { String(
        localized: "Stop batch transcription when Apple Speech makes no progress for this long.",
        bundle: bundle
    ) }

    static func batchTranscriptionStallTimeoutMinutes(_ minutes: Int) -> String {
        localizedCount(minutes, singular: "%lld minute", plural: "%lld minutes")
    }

    static var batchAudioRetentionPeriod: String { String(localized: "Local CAF Recording Retention", bundle: bundle) }
    static var batchAudioRetentionPeriodDescription: String { String(
        // swiftlint:disable:next line_length
        localized: "Local Workspace CAF recordings become eligible for deletion this long after both recording and transcription finish. Failed, unfinished, or active retranscription audio is kept. Server M4A storage is not affected.",
        bundle: bundle
    ) }
    static var forever: String { String(localized: "Forever", bundle: bundle) }
    static var shortenBatchAudioRetentionPeriodTitle: String { String(
        localized: "Shorten Recording Retention?",
        bundle: bundle
    ) }
    static var shortenBatchAudioRetentionPeriodMessage: String { String(
        localized: "Existing batch recordings older than the new retention period may be permanently deleted immediately.",
        bundle: bundle
    ) }

    static func days(_ days: Int) -> String {
        localizedCount(days, singular: "%lld day", plural: "%lld days")
    }

    static var liveSubtitleTranslation: String { String(localized: "Live Subtitle Translation", bundle: bundle) }
    static var liveSubtitleTranslationDescription: String { String(
        localized: "Translate live subtitles for display. This does not change the language of the saved transcript.",
        bundle: bundle
    ) }
    static var translationTargetLanguage: String { String(localized: "Target Language", bundle: bundle) }
    static var liveSubtitleTranslationTargetLanguageDescription: String { String(
        localized: "Choose which language translated live subtitles should use.",
        bundle: bundle
    ) }
    static var liveSubtitleTranslationDisabledForMatchingLiveTranscriptionLanguage: String { String(
        localized: "liveSubtitleTranslationDisabledForMatchingLiveTranscriptionLanguage",
        bundle: bundle
    ) }
    static var enableLiveSubtitleTranslationToChooseLanguage: String { String(
        localized: "Turn on live subtitle translation to choose a target language.",
        bundle: bundle
    ) }
    static var googleCalendar: String { String(localized: "Google Calendar", bundle: bundle) }
    static var macOSCalendar: String { String(localized: "macOS Calendar", bundle: bundle) }
    static var calendarSources: String { String(localized: "Calendar Sources", bundle: bundle) }
    static var calendarSourcesDescription: String { String(
        localized: "Turn on registered providers to combine their calendars. Add Google accounts in Providers. Each connection keeps its own calendar selection.",
        bundle: bundle
    ) }
    static var calendarProviderUnassigned: String { String(localized: "No provider selected", bundle: bundle) }
    static var calendarProviders: String { String(localized: "Calendar Providers", bundle: bundle) }
    static var renameProviderAccount: String { String(localized: "Rename Provider Account", bundle: bundle) }
    static var providerAccounts: String { String(localized: "Providers", bundle: bundle) }
    static var providerAccountsDescription: String { String(
        localized: "Sign in to the services Dahlia uses. Models, MCP servers, and calendars choose among these providers.",
        bundle: bundle
    ) }
    static var providerAccountSignInToKeep: String { String(localized: "Added earlier · Sign in again", bundle: bundle) }
    static var manageProviders: String { String(localized: "Manage Providers…", bundle: bundle) }
    static var googleDrive: String { String(localized: "Google Drive", bundle: bundle) }
    static var googleProviderAccountMismatch: String { String(
        localized: "Sign in with the same Google account. To use another account, add a provider.",
        bundle: bundle
    ) }
    static var googleDriveChooseProvider: String { String(
        localized: "Choose a registered provider here to read Google Drive backups. This choice is independent of Calendar.",
        bundle: bundle
    ) }
    static var googleProviderDisconnectPending: String { String(
        localized: "Sign-out incomplete. Retry to remove the saved credential.",
        bundle: bundle
    ) }
    static var googleProviderSignOutDescription: String { String(
        localized: "Disconnect this Google account from Calendar and Drive in Dahlia? Databricks connections are not affected.",
        bundle: bundle
    ) }
    static var googleProviderSignInDescription: String { String(
        localized: "Allow read-only access to Calendar and all Drive files. Dahlia reads selected Dahlia/Backup backups. Enable each feature in Settings. Drive access is optional.",
        bundle: bundle
    ) }
    static var googleProviderAuthorizeBoth: String { String(
        localized: "Authorize Calendar and Drive",
        bundle: bundle
    ) }

    static var renameProviderAccountDescription: String { String(
        localized: "The name shows only in Dahlia. Leave it empty to show the account details.",
        bundle: bundle
    ) }
    static var google: String { String(localized: "Google", bundle: bundle) }
    static var calendarProviderTurnOnToConnect: String { String(
        localized: "Turn this provider on to connect it.",
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
    static var calendarFilterUnconfirmedEvents: String { String(localized: "Unconfirmed events", bundle: bundle) }
    static var calendarIncludeUnconfirmedEventsDescription: String { String(
        localized: "Include events you have not accepted, except declined events.",
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
    static var calendarScheduleTitle: String { String(localized: "Upcoming schedule", bundle: bundle) }
    static var calendarAutoRecording: String { String(localized: "Auto-record", bundle: bundle) }
    static var calendarAutoRecordingScheduled: String { String(localized: "Auto-record scheduled", bundle: bundle) }
    static var calendarAutoRecordingHelp: String { String(
        localized: "Automatically start recording when this event begins.",
        bundle: bundle
    ) }

    static func calendarEventOrigin(_ title: String) -> String {
        String(localized: "Calendar event: \(title)", bundle: bundle)
    }

    static var googleCalendarDisplayCalendars: String { String(localized: "Display Calendars", bundle: bundle) }
    static var googleCalendarConnect: String { String(localized: "Connect", bundle: bundle) }
    static var googleCalendarDisconnect: String { String(localized: "Disconnect", bundle: bundle) }
    static var googleCalendarConnectDescription: String { String(
        localized: "Sign in with Google to load your upcoming schedule.",
        bundle: bundle
    ) }
    static var googleCalendarDatabricksConnectDescription: String { String(
        localized: "Sign in with Google in your Databricks workspace. The browser opens the connection page; Dahlia connects once you finish.",
        bundle: bundle
    ) }
    static var googleCalendarDatabricksConnected: String { String(
        localized: "Connected through your Databricks workspace. To revoke access, open the connection page in Databricks.",
        bundle: bundle
    ) }
    static var googleCalendarConnected: String { String(localized: "Connected", bundle: bundle) }
    static var googleCalendarNotConnected: String { String(localized: "No Google account connected", bundle: bundle) }
    static var googleCalendarOAuthDisclosureTitle: String { String(localized: "Connect Google Calendar", bundle: bundle) }
    static var googleCalendarOAuthDisclosureOverview: String { String(
        localized: """
        Dahlia requests read-only access to your Google account and the upcoming events in calendars you choose.
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
    static var googleOAuthDisclosureUseAndStorage: String { String(localized: "How Dahlia Uses and Stores It", bundle: bundle) }
    static var googleCalendarOAuthDisclosureUseAndStorage: String { String(
        localized: """
        OAuth tokens and your account ID, name, and email address are stored in Keychain. Upcoming events are shown in Dahlia. \
        Auto-recording stores the selected event occurrence identifier and its start and end dates in local settings until the recording attempt or event end. \
        Linked event details are stored in the local meeting database and any database backups you create while a saved meeting refers to them.
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
    static var googleOAuthDisclosureManageAndDelete: String { String(localized: "Manage and Delete", bundle: bundle) }
    static var googleCalendarOAuthDisclosureDeletion: String { String(
        localized: """
        Disconnecting Calendar stops its use in Dahlia and clears its calendar selection. The shared Google credential remains for Drive. \
        Sign out of the provider to remove it from this Mac. \
        Delete linked meetings to remove saved calendar details from the active database, and delete database backups separately.
        """,
        bundle: bundle
    ) }
    static var viewPrivacyPolicy: String { String(localized: "View Privacy Policy", bundle: bundle) }
    static var continueToGoogle: String { String(localized: "Continue to Google", bundle: bundle) }
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
        localized: "This build of Dahlia has no Google OAuth client ID, so it can't connect Google Calendar.",
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
        localized: "This Google OAuth client requires a client secret, which this build of Dahlia doesn't include.",
        bundle: bundle
    ) }
    static var googleAccountClientIDMissingMessage: String { String(
        localized: "This build of Dahlia has no Google OAuth client ID, so it can't connect Google services.",
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
    static var googleCalendarOpenDatabricksConnectionPage: String { String(
        localized: "Open Connection Page in Databricks",
        bundle: bundle
    ) }
    static var googleDatabricksReauthenticationRequired: String { String(
        localized: "Google rejected the credentials stored in Databricks. Open the connection page in Settings, revoke the credentials, sign in with Google again, then reconnect in Dahlia.",
        bundle: bundle
    ) }
    static func googleCalendarDatabricksProxyError(_ message: String) -> String { String(
        localized: "Databricks connection: \(message)",
        bundle: bundle
    ) }
    static func googleCalendarInvalidDate(_ value: String) -> String { String(
        localized: "Could not parse Google Calendar date: \(value)",
        bundle: bundle
    ) }

    // MARK: - Workspace Picker

    static var createNewWorkspace: String { String(localized: "Create New Workspace", bundle: bundle) }
    static var addWorkspace: String { String(localized: "Add Workspace", bundle: bundle) }
    static var openFolderAsWorkspace: String { String(localized: "Open Folder as Workspace", bundle: bundle) }
    static var removeWorkspace: String { String(localized: "Delete Workspace", bundle: bundle) }
    static var currentWorkspaceRemoveDescription: String { String(
        localized: "Open a different workspace before deleting this one.",
        bundle: bundle
    ) }
    static func removeWorkspaceConfirmation(_ name: String) -> String { String(localized: "Delete workspace \(name)?", bundle: bundle) }
    static var removeWorkspaceConfirmationDescription: String { String(
        localized: """
        Dahlia will remove this workspace and its meeting history from the app. \
        Audio files managed outside the workspace folder will also be deleted. \
        Files inside the workspace folder are not changed.
        """,
        bundle: bundle
    ) }
    static var workspaceContentHandling: String { String(localized: "Workspace Content", bundle: bundle) }
    static var transferWorkspaceContent: String { String(localized: "Move content to another workspace", bundle: bundle) }
    static var deleteWorkspaceContent: String { String(localized: "Delete content permanently", bundle: bundle) }
    static var workspaceTransferDestination: String { String(localized: "Destination Workspace", bundle: bundle) }
    static var selectWorkspaceTransferDestination: String { String(localized: "Select a workspace", bundle: bundle) }
    static var transferAndDeleteWorkspace: String { String(localized: "Move Content and Delete Workspace", bundle: bundle) }
    static var noWorkspaceTransferDestination: String { String(
        localized: "No other workspace in this account. Create one before moving content.",
        bundle: bundle
    ) }
    static var workspaceTransferDescription: String { String(
        localized: "Move projects, meetings, recordings, documents and instructions within this account. Duplicate names receive a number. Account chats and workspace settings are not moved.",
        bundle: bundle
    ) }
    static var workspaceExportFilesAreKept: String { String(localized: "Existing files in the export folder stay in place.", bundle: bundle) }
    static var workspaceDetails: String { String(localized: "Workspace Details", bundle: bundle) }
    static var workspaceName: String { String(localized: "Workspace Name", bundle: bundle) }
    static var workspaceNameDescription: String { String(localized: "Enter a name for the new workspace.", bundle: bundle) }
    static func renameWorkspace(_ name: String) -> String { String(localized: "Rename \(name)", bundle: bundle) }
    static var openWorkspace: String { String(localized: "Open Workspace", bundle: bundle) }
    static var openWorkspaceDescription: String { String(localized: "Use this workspace for recordings and sync.", bundle: bundle) }
    static var selectWorkspaceDescription: String { String(localized: "Select a workspace to view its details.", bundle: bundle) }
    static var noWorkspaces: String { String(localized: "No Workspaces", bundle: bundle) }
    static var noWorkspacesDescription: String { String(
        localized: "Add a folder to start recording and syncing meetings.",
        bundle: bundle
    ) }
    static var workspaceOperationFailed: String { String(localized: "Workspace Operation Failed", bundle: bundle) }
    static var workspaceFolderSelectionFailed: String { String(localized: "Could not select the workspace folder.", bundle: bundle) }
    static var workspaceLoadFailed: String { String(localized: "Could not load workspaces.", bundle: bundle) }
    static var workspaceAddFailed: String { String(localized: "Could not add the workspace.", bundle: bundle) }
    static var workspaceRenameFailed: String { String(localized: "Could not rename the workspace.", bundle: bundle) }
    static var workspaceRemoveFailed: String { String(localized: "Could not delete the workspace.", bundle: bundle) }
    static var open: String { String(localized: "Open", bundle: bundle) }
    static var loadingLanguages: String { String(localized: "Loading supported languages...", bundle: bundle) }
    static var searchLanguages: String { String(localized: "Search languages...", bundle: bundle) }
    static var noMatchingLanguages: String { String(localized: "No matching languages", bundle: bundle) }
    static func languagesSelected(_ count: Int) -> String { String(localized: "\(count) languages selected", bundle: bundle) }
    static func additionalLanguages(_ count: Int) -> String { String(localized: "\(count) more languages", bundle: bundle) }
    static var appLanguages: String { String(localized: "App Languages", bundle: bundle) }
    static var appLanguagesDescription: String { String(
        localized: "Limits languages shown for transcription and live subtitles, automatic language detection, and screenshot text extraction.",
        bundle: bundle
    ) }
    static var recordedLanguages: String { String(localized: "Recorded Languages", bundle: bundle) }
    static var transcriptionLanguage: String { String(localized: "Transcription Language", bundle: bundle) }
    static var settingsMeetingLinksIntro: String { String(localized: "settings.meetingLinks.intro", bundle: bundle) }
    static var meetingDataProcessing: String { String(localized: "meetingDataProcessing", bundle: bundle) }
    static var meetingProcessingVideo: String { String(localized: "meetingProcessingVideo", bundle: bundle) }
    static var meetingProcessingScreenshotCapture: String { String(localized: "meetingProcessingScreenshotCapture", bundle: bundle) }
    static var meetingProcessingFlowTitle: String { String(localized: "meetingProcessingFlowTitle", bundle: bundle) }
    static var meetingProcessingFlowHint: String { String(localized: "meetingProcessingFlowHint", bundle: bundle) }
    static var meetingProcessingAudio: String { String(localized: "meetingProcessingAudio", bundle: bundle) }
    static var meetingProcessingLiveTranscription: String { String(localized: "meetingProcessingLiveTranscription", bundle: bundle) }
    static var meetingProcessingSummaryGeneration: String { String(localized: "meetingProcessingSummaryGeneration", bundle: bundle) }
    static var meetingProcessingOpenWorkspaceSettings: String { String(localized: "meetingProcessingOpenWorkspaceSettings", bundle: bundle) }
    static var meetingProcessingImageRecognition: String { String(localized: "meetingProcessingImageRecognition", bundle: bundle) }
    static var liveTranscriptionLanguage: String { String(localized: "liveTranscriptionLanguage", bundle: bundle) }
    static var liveTranscriptionLanguageDescription: String { String(
        localized: "liveTranscriptionLanguageDescription",
        bundle: bundle
    ) }
    static var languageRange: String { String(localized: "Language Range", bundle: bundle) }
    static var allSupportedLanguages: String { String(localized: "All Supported Languages", bundle: bundle) }
    static var selectedLanguages: String { String(localized: "Selected Languages", bundle: bundle) }

    // MARK: - Settings (LLM)

    static var model: String { String(localized: "Model", bundle: bundle) }
    static func piRequestedModelUnavailable(_ model: String) -> String { String(
        localized: "Requested Pi model is unavailable: \(model)",
        bundle: bundle
    ) }
    static var codexHelperNotBundled: String { String(
        localized: "Dahlia's helper files are unavailable. Run Dahlia with scripts/run-dev.sh or install a signed app build.",
        bundle: bundle
    ) }
    static func codexLaunchFailed(_ detail: String) -> String { String(
        localized: "Could not start Pi: \(detail)",
        bundle: bundle
    ) }
    static var codexNotLoggedIn: String { String(
        localized: "Pi is not signed in. Sign in under Settings > Providers, then try again.",
        bundle: bundle
    ) }
    static func codexLoginFailed(_ detail: String) -> String { String(
        localized: "Pi sign-in failed: \(detail)",
        bundle: bundle
    ) }
    static var codexLoginFailedWithoutDetail: String { String(localized: "Pi sign-in failed.", bundle: bundle) }
    static var codexLoginPageCouldNotOpen: String { String(
        localized: "Could not open the Pi sign-in page.",
        bundle: bundle
    ) }
    static var codexProcessExited: String { String(localized: "Pi exited unexpectedly.", bundle: bundle) }
    static func codexProcessExitedWithDetail(_ detail: String) -> String { String(
        localized: "Pi exited unexpectedly: \(detail)",
        bundle: bundle
    ) }
    static func codexRequestTimedOut(_ operation: String) -> String { String(
        localized: "Pi did not respond in time (\(operation)). Try again.",
        bundle: bundle
    ) }
    static var codexInvalidResponse: String { String(localized: "Pi returned an invalid response.", bundle: bundle) }
    static func codexRequestFailed(_ detail: String) -> String { String(
        localized: "Pi request failed: \(detail)",
        bundle: bundle
    ) }
    static var codexTurnFailed: String { String(localized: "Pi could not complete the request.", bundle: bundle) }
    static var codexTurnInterrupted: String { String(localized: "Pi generation was interrupted.", bundle: bundle) }
    static var codexBackendResetForSafety: String {
        String(localized: "The AI backend was restarted to stop an unconfirmed operation safely.", bundle: bundle)
    }

    static var codexApprovalNoLongerPending: String {
        String(localized: "This approval request is no longer pending.", bundle: bundle)
    }

    static var account: String { String(localized: "Account", bundle: bundle) }
    static var features: String { String(localized: "settings.group.features", bundle: bundle) }

    static var chatGPTSubscription: String { String(localized: "ChatGPT Subscription", bundle: bundle) }
    static var databricks: String { String(localized: "Databricks", bundle: bundle) }
    static var unityGateway: String { String(localized: "Unity Gateway", bundle: bundle) }
    static var dataProtection: String { String(localized: "settings.dataProtection", bundle: bundle) }
    static var settingsDataProtectionIntro: String { String(localized: "settings.dataProtection.intro", bundle: bundle) }
    static var agents: String { String(localized: "settings.agents", bundle: bundle) }
    static var settingsAgentsIntro: String { String(localized: "settings.agents.intro", bundle: bundle) }
    static var settingsMeetingsIntro: String { String(localized: "settings.meetings.intro", bundle: bundle) }
    static var settingsDahliaMCPIntro: String { String(localized: "settings.dahliaMCP.intro", bundle: bundle) }
    static var unityGatewayMCPs: String { String(localized: "settings.agents.unityGatewayMCPs", bundle: bundle) }
    static var mcpLoadingServices: String { String(localized: "settings.agents.mcpLoadingServices", bundle: bundle) }
    static var mcpNoServices: String { String(localized: "settings.agents.mcpNoServices", bundle: bundle) }
    static var mcpRemoveWorkspaceDescription: String { String(localized: "settings.agents.mcpRemoveWorkspaceDescription", bundle: bundle) }

    static func mcpRemoveWorkspace(_ name: String) -> String {
        String(localized: "settings.agents.mcpRemoveWorkspace \(name)", bundle: bundle)
    }

    static var mcpAddService: String { String(localized: "settings.agents.mcpAddService", bundle: bundle) }
    static var mcpServiceName: String { String(localized: "settings.agents.mcpServiceName", bundle: bundle) }
    static var mcpServiceNameHelp: String { String(localized: "settings.agents.mcpServiceNameHelp", bundle: bundle) }
    static var mcpServiceNameInvalid: String { String(localized: "settings.agents.mcpServiceNameInvalid", bundle: bundle) }
    static var mcpServerNameInvalid: String { String(localized: "settings.agents.mcpServerNameInvalid", bundle: bundle) }
    static var mcpServerNameTaken: String { String(localized: "settings.agents.mcpServerNameTaken", bundle: bundle) }

    static func chatMCPSignInRequired(_ servers: String) -> String {
        String(localized: "chat.mcpSignInRequired \(servers)", bundle: bundle)
    }

    static func chatToolRunning(_ name: String) -> String {
        String(localized: "chat.toolRunning \(name)", bundle: bundle)
    }

    static func chatToolSucceeded(_ name: String) -> String {
        String(localized: "chat.toolSucceeded \(name)", bundle: bundle)
    }

    static func chatToolFailed(_ name: String) -> String {
        String(localized: "chat.toolFailed \(name)", bundle: bundle)
    }

    static func chatToolInaccessible(_ name: String) -> String {
        String(localized: "chat.toolInaccessible \(name)", bundle: bundle)
    }

    static var agentModels: String { String(localized: "settings.agents.models", bundle: bundle) }
    static var agentModelDetails: String { String(localized: "settings.agents.modelDetails", bundle: bundle) }
    static var agentModelID: String { String(localized: "settings.agents.modelID", bundle: bundle) }
    static var agentModelAPI: String { String(localized: "settings.agents.modelAPI", bundle: bundle) }
    static var agentModelEndpoint: String { String(localized: "settings.agents.modelEndpoint", bundle: bundle) }
    static var agentModelContextWindow: String { String(localized: "settings.agents.modelContextWindow", bundle: bundle) }
    static var agentModelMaxOutput: String { String(localized: "settings.agents.modelMaxOutput", bundle: bundle) }
    static var agentModelInput: String { String(localized: "settings.agents.modelInput", bundle: bundle) }
    static var agentModelReasoning: String { String(localized: "settings.agents.modelReasoning", bundle: bundle) }
    static var agentModelReasoningNone: String { String(localized: "settings.agents.modelReasoningNone", bundle: bundle) }
    static var agentModelPrice: String { String(localized: "settings.agents.modelPrice", bundle: bundle) }

    static func agentModelTokens(_ count: String) -> String {
        String(localized: "settings.agents.modelTokens \(count)", bundle: bundle)
    }

    /// USD per million tokens: input, output, cache read, and cache write.
    static func agentModelPriceValue(_ input: String, _ output: String, _ cacheRead: String, _ cacheWrite: String) -> String {
        String(localized: "settings.agents.modelPriceValue \(input) \(output) \(cacheRead) \(cacheWrite)", bundle: bundle)
    }

    static func agentModelPriceTier(_ count: String) -> String {
        String(localized: "settings.agents.modelPriceTier \(count)", bundle: bundle)
    }

    static var agentRuntime: String { String(localized: "settings.agents.runtime", bundle: bundle) }
    static var agentEnvironment: String { String(localized: "settings.agents.environment", bundle: bundle) }
    static var agentAddVariable: String { String(localized: "settings.agents.addVariable", bundle: bundle) }
    static var agentVariableName: String { String(localized: "settings.agents.variableName", bundle: bundle) }
    static var agentVariableValue: String { String(localized: "settings.agents.variableValue", bundle: bundle) }
    static var agentSecretStored: String { String(localized: "settings.agents.secretStored", bundle: bundle) }
    static var agentVariableMakeSecret: String { String(localized: "settings.agents.variableMakeSecret", bundle: bundle) }
    static var agentVariableMakePlain: String { String(localized: "settings.agents.variableMakePlain", bundle: bundle) }
    static var agentVariableNameInvalid: String { String(localized: "settings.agents.variableNameInvalid", bundle: bundle) }
    static var agentProviders: String { String(localized: "settings.agents.providers", bundle: bundle) }
    static var agentProviderModels: String { String(localized: "settings.agents.providerModels", bundle: bundle) }
    static var agentProviderStorage: String { String(localized: "settings.agents.providerStorage", bundle: bundle) }

    static var mcpAccountSignInRequired: String { String(localized: "settings.agents.mcpAccountSignInRequired", bundle: bundle) }

    static var addProvider: String { String(localized: "settings.agents.addProvider", bundle: bundle) }
    static var addProviderTitle: String { String(localized: "settings.agents.addProviderTitle", bundle: bundle) }
    static var agentProvidersEmpty: String { String(localized: "settings.agents.providersEmpty", bundle: bundle) }
    static var signInAgain: String { String(localized: "settings.agents.signInAgain", bundle: bundle) }
    static var providerRegistered: String { String(localized: "settings.providers.registered", bundle: bundle) }
    static var registeredProviderSignInAgainHint: String { String(localized: "settings.providers.registeredSignInAgainHint", bundle: bundle) }
    static var mcpServiceSignedIn: String { String(localized: "settings.agents.mcpServiceSignedIn", bundle: bundle) }
    static var mcpServiceSignInRequired: String { String(localized: "settings.agents.mcpServiceSignInRequired", bundle: bundle) }
    static var mcpServiceSignInUnknown: String { String(localized: "settings.agents.mcpServiceSignInUnknown", bundle: bundle) }

    static var mcpSearchPrompt: String { String(localized: "settings.agents.mcpSearchPrompt", bundle: bundle) }
    static var mcpNoProviders: String { String(localized: "settings.agents.mcpNoProviders", bundle: bundle) }
    static var mcpProviderSignInRequired: String { String(localized: "settings.agents.mcpProviderSignInRequired", bundle: bundle) }
    static var mcpWorkspaceIsAccount: String { String(localized: "settings.agents.mcpWorkspaceIsAccount", bundle: bundle) }

    /// MCP services or models turned on.
    static func agentEnabledCount(_ count: Int) -> String {
        String(localized: "settings.agents.enabledCount \(count)", bundle: bundle)
    }

    static func mcpServiceWithServerName(_ service: String, _ name: String) -> String {
        String(localized: "settings.agents.mcpServiceWithServerName \(service) \(name)", bundle: bundle)
    }

    static func unityGatewayHost(_ host: String) -> String {
        String(localized: "settings.agents.unityGatewayHost \(host)", bundle: bundle)
    }

    static var agentMCPs: String { String(localized: "settings.agents.mcps", bundle: bundle) }
    static var piCommandInUse: String { String(localized: "settings.agents.piCommandInUse", bundle: bundle) }
    static var agentSkills: String { String(localized: "settings.agents.skills", bundle: bundle) }
    static var agentSkillsEmpty: String { String(localized: "settings.agents.skills.empty", bundle: bundle) }
    static var agentSkillsHelp: String { String(localized: "settings.agents.skills.help", bundle: bundle) }
    static var agentSkillOpenFolder: String { String(localized: "settings.agents.skills.openFolder", bundle: bundle) }
    static var agentSkillDetails: String { String(localized: "settings.agents.skills.details", bundle: bundle) }
    static var agentSkillOpenFolderFailed: String { String(localized: "settings.agents.skills.openFolderFailed", bundle: bundle) }
    static var agentSkillContentUnavailable: String { String(localized: "settings.agents.skills.contentUnavailable", bundle: bundle) }
    static var agentSkillsPathConflict: String { String(localized: "settings.agents.skills.pathConflict", bundle: bundle) }
    static var agentFileAccessBuiltIn: String { String(localized: "settings.agents.fileAccess.builtIn", bundle: bundle) }
    static var agentFileAccessDahliaData: String { String(localized: "settings.agents.fileAccess.dahliaData", bundle: bundle) }
    static var agentFileAccessDahliaDataHelp: String { String(localized: "settings.agents.fileAccess.dahliaDataHelp", bundle: bundle) }
    static var agentFileAccessSystemFolders: String { String(localized: "settings.agents.fileAccess.systemFolders", bundle: bundle) }
    static var agentFileAccessBuiltInHelp: String { String(localized: "settings.agents.fileAccess.builtInHelp", bundle: bundle) }
    static var agentSecurity: String { String(localized: "settings.agents.security", bundle: bundle) }
    static var agentFileAccess: String { String(localized: "settings.agents.fileAccess", bundle: bundle) }
    static var agentFileAccessPermission: String { String(localized: "settings.agents.fileAccess.permission", bundle: bundle) }
    static var agentFileAccessReadOnly: String { String(localized: "settings.agents.fileAccess.readOnly", bundle: bundle) }
    static var agentFileAccessReadWrite: String { String(localized: "settings.agents.fileAccess.readWrite", bundle: bundle) }
    static var agentFileAccessAdd: String { String(localized: "settings.agents.fileAccess.add", bundle: bundle) }
    static var agentFileAccessRemove: String { String(localized: "settings.agents.fileAccess.remove", bundle: bundle) }
    static var agentFileAccessDefaults: String { String(localized: "settings.agents.fileAccess.defaults", bundle: bundle) }
    static var agentFileAccessHelp: String { String(localized: "settings.agents.fileAccess.help", bundle: bundle) }
    static var agentShellStartupPathRequired: String { String(localized: "settings.agents.shellStartupPathRequired", bundle: bundle) }
    static var agentFileAccessChanged: String { String(localized: "settings.agents.fileAccess.changed", bundle: bundle) }
    static var agentFileAccessNotAllowed: String { String(localized: "settings.agents.fileAccess.notAllowed", bundle: bundle) }
    static var agentWorkingDirectory: String { String(localized: "settings.agents.workingDirectory", bundle: bundle) }
    static var agentWorkingDirectoryHelp: String { String(localized: "settings.agents.workingDirectory.help", bundle: bundle) }
    static var agentWorkingDirectoryNotAllowed: String { String(localized: "settings.agents.workingDirectory.notAllowed", bundle: bundle) }
    static var piCommandNotFound: String { String(
        localized: "Pi was not found on PATH. You can install Dahlia-managed Pi from Settings.",
        bundle: bundle
    ) }
    static var piNotInstalled: String { String(localized: "settings.agents.piNotInstalled", bundle: bundle) }
    static var installPi: String { String(localized: "settings.agents.installPi", bundle: bundle) }
    static var updatePi: String { String(localized: "settings.agents.updatePi", bundle: bundle) }
    static var useManagedPi: String { String(localized: "settings.agents.useManagedPi", bundle: bundle) }
    static func piInstalledVersion(_ version: String) -> String { String(
        localized: "Pi \(version) installed by Dahlia",
        bundle: bundle
    ) }
    static func piInstalled(_ version: String) -> String { String(localized: "Installed Pi \(version).", bundle: bundle) }
    static func piUpToDate(_ version: String) -> String { String(
        localized: "Pi \(version) is the latest version.",
        bundle: bundle
    ) }
    static func piInstallFailed(_ stage: String, _ reason: String) -> String { String(
        localized: "Pi installation failed — \(stage): \(reason)",
        bundle: bundle
    ) }
    static var piInstallReleaseStage: String { String(localized: "Release information", bundle: bundle) }
    static var piInstallDownloadStage: String { String(localized: "Download", bundle: bundle) }
    static var piInstallVerificationStage: String { String(localized: "Verification", bundle: bundle) }
    static var piInstallExtractionStage: String { String(localized: "Extraction", bundle: bundle) }
    static var piInstallActivationStage: String { String(localized: "Installation activation", bundle: bundle) }
    static var piInstallHTTPFailed: String { String(localized: "GitHub returned an error. Try again later.", bundle: bundle) }
    static var piInstallRateLimited: String { String(
        localized: "GitHub has limited requests from this network. Wait before trying again, or use another network.",
        bundle: bundle
    ) }
    static var piInstallInvalidResponse: String { String(localized: "The server returned an unexpected response. Try again later.", bundle: bundle) }
    static var piInstallInvalidRelease: String { String(localized: "The Pi release information is invalid. Try again later.", bundle: bundle) }
    static var piInstallMissingAsset: String { String(
        localized: "This Pi release has no macOS Apple Silicon download. Try again later.",
        bundle: bundle
    ) }
    static var piInstallMissingDigest: String { String(localized: "This Pi release has no SHA-256 checksum. Try again later.", bundle: bundle) }
    static var piInstallChecksumMismatch: String { String(
        localized: "The downloaded file failed SHA-256 verification. Download it again; if this continues, check your network.",
        bundle: bundle
    ) }
    static var piInstallExtractionFailed: String { String(
        localized: "The downloaded archive could not be extracted. Check available disk space and try again.",
        bundle: bundle
    ) }
    static var piInstallExecutableMissing: String { String(
        localized: "The extracted archive has no executable Pi. Try downloading it again.",
        bundle: bundle
    ) }
    static var piInstallNetworkTimeout: String { String(
        localized: "The request timed out. Check your network connection and try again.",
        bundle: bundle
    ) }
    static var piInstallNetworkOffline: String { String(
        localized: "There is no internet connection. Connect to the internet and try again.",
        bundle: bundle
    ) }
    static var piInstallNetworkTLS: String { String(
        localized: "A secure connection could not be established. Check your network and certificate settings.",
        bundle: bundle
    ) }
    static var piInstallNetworkFailed: String { String(
        localized: "A network connection failed. Check your network or proxy settings and try again.",
        bundle: bundle
    ) }
    static var piInstallFileSystemFailed: String { String(
        localized: "A file could not be read or saved. Check disk space and installation-folder permissions.",
        bundle: bundle
    ) }
    static func piExecutableNotFound(_ path: String) -> String { String(
        localized: "No executable Pi at \(path). Install Pi in Settings > Dahlia AI.",
        bundle: bundle
    ) }
    static var codexSignedIn: String { String(localized: "Signed in", bundle: bundle) }
    static var cancelSignIn: String { String(localized: "Cancel Sign-In", bundle: bundle) }
    static var signOut: String { String(localized: "Sign Out", bundle: bundle) }
    static var databricksProfileRequired: String { String(localized: "Connect a Databricks workspace.", bundle: bundle) }
    static var databricksWorkspaceURLInvalid: String { String(
        localized: "Enter a valid HTTPS Databricks workspace root URL.",
        bundle: bundle
    ) }
    static var workspaceURL: String { String(localized: "settings.agents.workspaceURL", bundle: bundle) }
    static var databricksWorkspaceURLPlaceholder: String { String(
        localized: "https://your-workspace.cloud.databricks.com",
        bundle: bundle
    ) }
    static func codexConfigurationUpdateFailed(_ detail: String) -> String { String(
        localized: "Could not update the Pi configuration: \(detail)",
        bundle: bundle
    ) }
    static var codexAccountConfigurationNotReady: String { String(
        localized: "The selected AI account is not ready. Open Accounts and Workspaces in Settings and finish its configuration.",
        bundle: bundle
    ) }
    static var codexNoModels: String { String(localized: "Pi returned no available models. Try again.", bundle: bundle) }
    static var fallbackModel: String { String(localized: "Fallback Model", bundle: bundle) }
    static var fallbackModelDescription: String { String(
        localized: "Try this model once if generation fails or returns an invalid response. None disables fallback.",
        bundle: bundle
    ) }
    static var reasoningEffort: String { String(localized: "Reasoning Effort", bundle: bundle) }

    static var imageAnalysisModelDescription: String { String(
        localized: "Used for searchable image text and captions, and for choosing useful screenshots before summary generation.",
        bundle: bundle
    ) }

    static var reasoningEffortDescription: String { String(
        localized: "Controls how much reasoning Pi uses for each summary.",
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
    static var summaryDetailLevel: String { String(localized: "Detail Level", bundle: bundle) }
    static var summaryDetailLevelDescription: String { String(
        localized: "Controls how much information is included in each summary.",
        bundle: bundle
    ) }
    static var summaryDetailConcise: String { String(localized: "Concise", bundle: bundle) }
    static var summaryDetailStandard: String { String(localized: "Standard", bundle: bundle) }
    static var summaryDetailDetailed: String { String(localized: "Detailed", bundle: bundle) }
    static var summaryDetailMax: String { String(localized: "Event Play-by-Play", bundle: bundle) }
    static var summaryDetailEventSession: String { String(localized: "Event Session", bundle: bundle) }
    static var summaryOutputLanguage: String { String(localized: "Output Language", bundle: bundle) }
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
    static var exportToGoogleDrive: String { String(localized: "share.exportToGoogleDrive", bundle: bundle) }
    static var exportToGoogleDrivePrompt: String { String(localized: "share.exportToGoogleDrivePrompt", bundle: bundle) }
    static var copySummaryForGoogleDocs: String { String(localized: "Copy for Google Docs", bundle: bundle) }
    static var copySummaryForSlack: String { String(localized: "Copy for Slack", bundle: bundle) }

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
    static var recordingWithoutMicrophonePermission: String { String(
        localized: "Recording without the microphone because access is denied. Allow it in System Settings > Privacy & Security > Microphone, then turn the microphone off and select it again.",
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
        localized: "View recent Dahlia logs, including earlier app sessions.",
        bundle: bundle
    ) }
    static var applicationLogsUnavailable: String { String(localized: "Logs Unavailable", bundle: bundle) }
    static var noApplicationLogs: String { String(localized: "No Logs", bundle: bundle) }
    static var noApplicationLogsDescription: String { String(
        localized: "New logs appear here automatically.",
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

    static var mcpSettings: String { String(localized: "MCP Settings", bundle: bundle) }
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
        localized: "Choose which event details appear in the menu bar. It shows events from the calendars chosen under Account > Calendar, filtered on the Event Display tab.",
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

    static func joinMeetingService(_ service: String) -> String {
        String(format: String(localized: "Join %@", bundle: bundle), locale: .current, service)
    }

    static var calendarOpenInCalendar: String { String(localized: "Open in Calendar", bundle: bundle) }
    static var menuBarEventDetails: String { String(localized: "Event Details", bundle: bundle) }
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

    static var chatSteer: String { String(localized: "Steer", bundle: bundle) }
    static var chatQueue: String { String(localized: "Queue", bundle: bundle) }
    static var chatSendNow: String { String(localized: "Send now", bundle: bundle) }
    static var chatClearCommandDescription: String {
        String(localized: "Start a fresh session; earlier messages stay visible", bundle: bundle)
    }

    static var chatFreshSessionArmed: String { String(localized: "Your next message starts a fresh session", bundle: bundle) }
    static var chatFreshSessionArmedDetail: String {
        String(localized: "The agent won't see earlier messages in this thread.", bundle: bundle)
    }

    static var chatKeepCurrentSession: String { String(localized: "Keep the current session", bundle: bundle) }
    static var chatNewSession: String { String(localized: "New session", bundle: bundle) }
    static var chatFollowUpBehavior: String { String(localized: "Follow-up behavior", bundle: bundle) }
    static var chatSettledSection: String { String(localized: "chat.settledSection", bundle: bundle) }

    static func chatShowMore(_ count: Int) -> String {
        String(format: String(localized: "chat.showMore", bundle: bundle), locale: .current, count)
    }

    static var chatSettleThread: String { String(localized: "chat.settleThread", bundle: bundle) }
    static var chatCannotSettleActiveThread: String { String(localized: "chat.cannotSettleActiveThread", bundle: bundle) }
    static var chatUnsettleThread: String { String(localized: "chat.unsettleThread", bundle: bundle) }
    static var chatContinueAfterRestart: String { String(localized: "Continue chats after a crash", bundle: bundle) }
    static var chatContinueAfterRestartHelp: String { String(localized: "chat.continueAfterRestart.help", bundle: bundle) }
    static var chatContinuedAfterRestart: String { String(localized: "chat.continuedAfterRestart", bundle: bundle) }
    static var chatFollowUpHelp: String { String(
        localized: "While responding, send using the default behavior. Hold Command or press Command-Return to use the other action.",
        bundle: bundle
    ) }
    static var chatQueuePaused: String { String(localized: "Queue paused", bundle: bundle) }
    static var chatSkipAndContinue: String { String(localized: "Skip and continue", bundle: bundle) }
    static var chatResumeQueue: String { String(localized: "Resume queue", bundle: bundle) }

    static var chatNoticeExpanded: String { String(localized: "Chat notice expanded", bundle: bundle) }
    static var chatNoticeCollapsed: String { String(localized: "Chat notice collapsed", bundle: bundle) }
    static var omnigent: String { String(localized: "Omnigent", bundle: bundle) }
    static var omnigentEnabled: String { String(localized: "settings.agents.omnigent.enabled", bundle: bundle) }
    static var omnigentEnabledHelp: String { String(localized: "settings.agents.omnigent.enabledHelp", bundle: bundle) }
    static var omnigentRefresh: String { String(localized: "sidebar.omnigent.refresh", bundle: bundle) }
    static var omnigentNoSessions: String { String(localized: "sidebar.omnigent.noSessions", bundle: bundle) }
    static var omnigentNoMessages: String { String(localized: "omnigent.session.noMessages", bundle: bundle) }
    static var omnigentOpenInBrowser: String { String(localized: "omnigent.session.openInBrowser", bundle: bundle) }
    static var chatSlashCommands: String { String(localized: "Commands and skills", bundle: bundle) }
    static var chatNoMatchingCommands: String { String(localized: "No matching commands or skills.", bundle: bundle) }
    static var chatCommandsLoadFailed: String { String(localized: "Could not load commands. Type / again to retry.", bundle: bundle) }

    static var chat: String { String(localized: "Chat", bundle: bundle) }
    static var dahliaAI: String { String(localized: "Dahlia AI", bundle: bundle) }
    static var newChat: String { String(localized: "New chat", bundle: bundle) }
    static var chatSelectProject: String { String(localized: "Select chat project", bundle: bundle) }
    static var chatHistory: String { String(localized: "Chat history", bundle: bundle) }
    static var chatWelcomeTitle: String { String(localized: "How can I help?", bundle: bundle) }
    static var chatConnectorSettings: String { String(localized: "Connector settings", bundle: bundle) }
    static var chatNoMCPServers: String { String(localized: "No connectors registered.", bundle: bundle) }
    static var chatAppIntegrations: String { String(localized: "App integrations", bundle: bundle) }
    static var chatConfigureAppIntegrations: String { String(localized: "Configure app integrations", bundle: bundle) }
    static var recentChats: String { String(localized: "Recent chats", bundle: bundle) }
    static var noRecentChats: String { String(localized: "No recent chats", bundle: bundle) }
    static var loadMore: String { String(localized: "Load more", bundle: bundle) }
    static var chatEarlierMessages: String { String(localized: "Earlier messages", bundle: bundle) }
    static var chatLaterMessages: String { String(localized: "Later messages", bundle: bundle) }
    static var showChatFullScreen: String { String(localized: "Show chat full screen", bundle: bundle) }
    static var hideChat: String { String(localized: "Hide chat", bundle: bundle) }
    static var showChat: String { String(localized: "Show chat", bundle: bundle) }
    static var shown: String { String(localized: "Shown", bundle: bundle) }
    static var hidden: String { String(localized: "Hidden", bundle: bundle) }
    static var sendMessage: String { String(localized: "Send message", bundle: bundle) }
    static var stopGenerating: String { String(localized: "Stop generating", bundle: bundle) }
    static var chatThinking: String { String(localized: "Thinking", bundle: bundle) }
    static var chatCompactDoesNotSupportImages: String { String(localized: "Remove attached images before compacting context", bundle: bundle) }
    static var chatCompacting: String { String(localized: "Compacting context", bundle: bundle) }
    static var chatCompactCommandDescription: String {
        String(localized: "Summarize the conversation and reduce context usage", bundle: bundle)
    }

    static func chatCompacted(from before: String, to after: String) -> String {
        String(localized: "Context compacted \(before) → \(after) tokens", bundle: bundle)
    }

    static var messageDahliaAI: String { String(localized: "Message Dahlia AI", bundle: bundle) }
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
    static var chatUserInputOther: String { String(localized: "Other", bundle: bundle) }
    static var chatUserInputSubmit: String { String(localized: "Submit", bundle: bundle) }
    static var chatCustomInstructions: String { String(localized: "settings.agents.customInstructions", bundle: bundle) }
    static var chatCustomInstructionsUseForSummary: String { String(localized: "settings.agents.customInstructions.useForSummary", bundle: bundle) }
    static var chatCustomInstructionsHelp: String { String(localized: "settings.agents.customInstructions.help", bundle: bundle) }
    static var chatCustomInstructionsDetails: String { String(localized: "settings.agents.customInstructions.details", bundle: bundle) }
    static var chatCustomInstructionsInfo: String { String(localized: "settings.agents.customInstructions.info", bundle: bundle) }
    static var autoReviewSettings: String { String(localized: "Auto review", bundle: bundle) }
    static var autoReviewModel: String { String(localized: "Reviewer model", bundle: bundle) }
    static var autoReviewModelHelp: String { String(localized: "settings.agents.autoReview.model.help", bundle: bundle) }
    static var autoReviewUseChatModel: String { String(localized: "Same as chat", bundle: bundle) }
    static var autoReviewTriage: String { String(localized: "settings.agents.autoReview.triage", bundle: bundle) }
    static var autoReviewTriageHelp: String { String(localized: "settings.agents.autoReview.triage.help", bundle: bundle) }
    static var autoReviewTriageUnavailable: String { String(localized: "settings.agents.autoReview.triage.unavailable", bundle: bundle) }
    static var autoReviewSettingsDescription: String { String(
        localized: "Used when AI reviews MCP actions. Reviews send chat history and the planned action to this model and incur additional usage. Changes apply to the next review.",
        bundle: bundle
    ) }

    static var chatApprovalMethod: String { String(localized: "Approval method", bundle: bundle) }
    static var chatChangePermissions: String { String(localized: "Change permissions", bundle: bundle) }
    static var chatApprovalAsk: String { String(localized: "Always ask", bundle: bundle) }
    static var chatApprovalAskDescription: String { String(
        localized: "Confirm before making changes or sending content.",
        bundle: bundle
    ) }
    static var chatApprovalAutoReview: String { String(localized: "Ask with AI", bundle: bundle) }
    static var chatApprovalAutoReviewDescription: String { String(
        localized: "Ask only about potentially unsafe actions.",
        bundle: bundle
    ) }
    static var chatApprovalAutoReviewUnavailable: String { String(
        localized: "chat.approval.autoReview.unavailable",
        bundle: bundle
    ) }

    static var chatApprovalFullAccess: String { String(localized: "Skip all approvals", bundle: bundle) }
    static var chatApprovalFullAccessDescription: String { String(
        localized: "Run without asking. Use with caution.",
        bundle: bundle
    ) }

    static var chatApprovalSandboxScope: String { String(
        localized: "File operations run in a sandbox and cannot access files outside the allowed scope.", bundle: bundle
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

    static var openAISettings: String { String(localized: "Open Accounts and Workspaces Settings", bundle: bundle) }
    static var openAgentSettings: String { String(localized: "chat.openAgentSettings", bundle: bundle) }
    static var chatModelLoading: String { String(localized: "Loading models…", bundle: bundle) }
    static var chatThreadRunning: String { String(localized: "Chat is running", bundle: bundle) }
    static var chatThreadRunningShort: String { String(localized: "chat.thread.runningShort", bundle: bundle) }
    static var chatThreadWaitingShort: String { String(localized: "chat.thread.waitingShort", bundle: bundle) }
    static var chatThreadWaitingForUser: String {
        String(localized: "Waiting for your response or approval", bundle: bundle)
    }

    static var chatWindowUnavailable: String { String(localized: "This chat is no longer available.", bundle: bundle) }
    static var resize: String { String(localized: "Resize", bundle: bundle) }
    static func chatProjectOrganizationShortcutTitle(_ days: Int) -> String {
        String(localized: "Organize meetings and Projects from the last \(days) days", bundle: bundle)
    }

    static var chatMeetingReviewShortcutTitle: String {
        String(localized: "Review meeting speech", bundle: bundle)
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
    static var chatForkFromResponse: String { String(localized: "Fork from this response (coming soon)", bundle: bundle) }
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

    static var liveTranscriptDraft: String { String(localized: "liveTranscriptDraft", bundle: bundle) }
    static var liveTranscriptDraftSectionTitle: String { String(localized: "liveTranscriptDraftSectionTitle", bundle: bundle) }
    static var automaticRecordingProcessing: String { String(localized: "automaticRecordingProcessing", bundle: bundle) }
    static var processingConfirmationTitle: String { String(localized: "録音を処理", bundle: bundle) }
    static var processingConfirmationDescription: String { String(localized: "保存した録音から文字起こしと要約を作成します。", bundle: bundle) }
    static var startProcessing: String { String(localized: "処理を開始", bundle: bundle) }
    static var processingLocalTranscription: String { String(localized: "processingLocalTranscription", bundle: bundle) }
    static var processingCloudTranscription: String { String(localized: "processingCloudTranscription", bundle: bundle) }
    static var processingDirectAudio: String { String(localized: "processingDirectAudio", bundle: bundle) }
    static var processingMethod: String { String(localized: "processingMethod", bundle: bundle) }
    static var processingUploading: String { String(localized: "processingUploading", bundle: bundle) }
    static var processingTranscribing: String { String(localized: "processingTranscribing", bundle: bundle) }
    static var processingSummarizing: String { String(localized: "processingSummarizing", bundle: bundle) }
    static var processingGenerating: String { String(localized: "processingGenerating", bundle: bundle) }
    static var processingSaving: String { String(localized: "processingSaving", bundle: bundle) }
    static var processingFailureDismissalFailed: String { String(localized: "processingFailureDismissalFailed", bundle: bundle) }
    static var processingCancelled: String { String(localized: "processingCancelled", bundle: bundle) }
    static var transcriptionModel: String { String(localized: "transcriptionModel", bundle: bundle) }
}

extension L10n {
    static var databricksAuthorizationTimedOut: String { String(
        localized: "Databricks sign-in timed out. Please sign in again.",
        bundle: bundle
    ) }
    static var databricksInvalidAuthorizationResponse: String { String(
        localized: "Databricks sign-in returned an invalid response. Please sign in again.",
        bundle: bundle
    ) }
    static var databricksWorkspaceAlreadyConnected: String { String(
        localized: "Sign out before connecting to another Databricks workspace.",
        bundle: bundle
    ) }
    static var databricksCallbackUnavailable: String { String(
        localized: "Cannot listen on any of localhost ports 8020–8040. Close the other sign-ins and retry.",
        bundle: bundle
    ) }

}
