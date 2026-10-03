import Foundation

enum CodexChatMeetingPickerSelection {
    static func moving(
        currentID: UUID?,
        in references: [CodexChatMeetingReference],
        by offset: Int
    ) -> UUID? {
        guard !references.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = references.firstIndex(where: { $0.id == currentID })
        else { return references[0].id }
        let nextIndex = min(references.count - 1, max(0, currentIndex + offset))
        return references[nextIndex].id
    }
}
