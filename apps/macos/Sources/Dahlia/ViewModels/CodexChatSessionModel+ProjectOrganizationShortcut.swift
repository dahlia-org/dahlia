import Foundation

extension CodexChatSessionModel {
    var showsProjectOrganizationShortcut: Bool {
        backendThreadID == nil && messages.isEmpty
    }

    var canSendProjectOrganizationShortcut: Bool {
        showsProjectOrganizationShortcut && isBoundToCurrentWorkspace && !isGenerating
    }

    func sendProjectOrganizationShortcut(
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        guard canSendProjectOrganizationShortcut else { return }
        usageTelemetryReporter(.aiChatPromptSubmitted)
        submit(CodexChatProjectOrganizationShortcut.prompt(now: now, calendar: calendar))
    }
}
