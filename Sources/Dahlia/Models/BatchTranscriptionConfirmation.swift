import Foundation

struct BatchTranscriptionProjectSelection: Equatable {
    let projects: [FlatProjectRow]
    let selectedProjectId: UUID?
    let errorMessage: String?

    static let unavailable = Self(
        projects: [],
        selectedProjectId: nil,
        errorMessage: nil
    )
}

struct BatchTranscriptionConfirmation: Identifiable, Equatable {
    enum Purpose: Equatable {
        case initialOrRetry
        case retranscription(sessionIds: [UUID])
    }

    let sessionId: UUID
    let meetingId: UUID
    let suggestedLocaleIdentifier: String
    let initialLanguageSelection: BatchTranscriptionLanguageSelection
    let allowsRecordedLanguageSelection: Bool
    let automaticLanguageCandidateSnapshot: BatchLanguageDetectionCandidateSnapshot?
    let purpose: Purpose
    let initiallyGeneratesSummary: Bool
    let summaryGenerationOptions: SummaryGenerationOptions
    let projectSelection: BatchTranscriptionProjectSelection

    init(
        sessionId: UUID,
        meetingId: UUID,
        suggestedLocaleIdentifier: String,
        initialLanguageSelection: BatchTranscriptionLanguageSelection? = nil,
        allowsRecordedLanguageSelection: Bool? = nil,
        automaticLanguageCandidateSnapshot: BatchLanguageDetectionCandidateSnapshot? = nil,
        purpose: Purpose = .initialOrRetry,
        initiallyGeneratesSummary: Bool = false,
        summaryGenerationOptions: SummaryGenerationOptions = .manual,
        projectSelection: BatchTranscriptionProjectSelection = .unavailable
    ) {
        if case let .retranscription(sessionIds) = purpose {
            precondition(!sessionIds.isEmpty && sessionIds.contains(sessionId))
        }
        self.sessionId = sessionId
        self.meetingId = meetingId
        self.suggestedLocaleIdentifier = suggestedLocaleIdentifier
        let resolvedLanguageSelection = initialLanguageSelection
            ?? .manual(localeIdentifier: suggestedLocaleIdentifier)
        self.initialLanguageSelection = resolvedLanguageSelection
        self.allowsRecordedLanguageSelection = allowsRecordedLanguageSelection
            ?? (resolvedLanguageSelection == .recorded)
        self.automaticLanguageCandidateSnapshot = automaticLanguageCandidateSnapshot
        self.purpose = purpose
        self.initiallyGeneratesSummary = initiallyGeneratesSummary
        self.summaryGenerationOptions = summaryGenerationOptions
        self.projectSelection = projectSelection
    }

    var id: UUID { sessionId }

    var isRetranscription: Bool {
        if case .retranscription = purpose { true } else { false }
    }
}
