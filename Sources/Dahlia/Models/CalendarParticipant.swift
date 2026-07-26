import DahliaRuntimeSupport
import Foundation

struct CalendarParticipant: Codable, Equatable, Sendable {
    let email: String?
    let displayName: String?
    let role: MeetingParticipantRole
    let responseStatus: MeetingParticipantResponseStatus
    let kind: CalendarParticipantKind
    let isCurrentUser: Bool
    let source: String

    func mergingMissingMetadata(from fallback: Self) -> Self {
        Self(
            email: email ?? fallback.email,
            displayName: CustomerIdentityNormalizer.displayName(displayName)
                ?? CustomerIdentityNormalizer.displayName(fallback.displayName),
            role: role == .unknown ? fallback.role : role,
            responseStatus: responseStatus == .unknown ? fallback.responseStatus : responseStatus,
            kind: kind == .unknown ? fallback.kind : kind,
            isCurrentUser: isCurrentUser || fallback.isCurrentUser,
            source: source
        )
    }
}
