import Foundation

extension SidebarViewModel {
    private static let tagColorPalette = [
        "#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4",
        "#FFEAA7", "#DDA0DD", "#98D8C8", "#F7DC6F",
        "#BB8FCE", "#85C1E9",
    ]

    func renameMeeting(id: UUID, newName: String) {
        do {
            try meetingRepository?.renameMeeting(id: id, newName: newName)
            updateCachedMeetingName(id: id, name: newName)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addTagToMeeting(id: UUID, tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let colorHex = Self.tagColorPalette.randomElement() ?? "#808080"
        try? meetingRepository?.addTag(name: trimmed, toMeetingId: id, colorHex: colorHex)
        restartCurrentMeetingSearch()
    }

    func removeTagFromMeeting(id: UUID, tag: String) {
        try? meetingRepository?.removeTag(name: tag, fromMeetingId: id)
        restartCurrentMeetingSearch()
    }

    func deleteMeetings(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        guard let meetingRepository else { return }
        Task {
            do {
                try await meetingRepository.deleteMeetingsSafely(ids: ids)
                removeCachedMeetings(ids: ids)
                selectedMeetingIds.subtract(ids)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func moveMeeting(id: UUID, toProjectId: UUID?) -> Bool {
        guard let projectWorkspaceService else { return false }
        do {
            try projectWorkspaceService.moveMeeting(id: id, toProjectId: toProjectId)
            let projectName = toProjectId.flatMap { projectId in
                allProjectItems.first(where: { $0.projectId == projectId })?.projectName
            }
            updateCachedMeetingProject(id: id, projectId: toProjectId, projectName: projectName)
            restartCurrentMeetingSearch()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func moveMeetings(ids: Set<UUID>, toProjectId: UUID?) -> Bool {
        guard let projectWorkspaceService, !ids.isEmpty else { return false }
        do {
            try projectWorkspaceService.moveMeetings(ids: ids, toProjectId: toProjectId)
            let projectName = toProjectId.flatMap { projectId in
                allProjectItems.first(where: { $0.projectId == projectId })?.projectName
            }
            for id in ids {
                updateCachedMeetingProject(id: id, projectId: toProjectId, projectName: projectName)
            }
            restartCurrentMeetingSearch()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
