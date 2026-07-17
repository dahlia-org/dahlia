import Foundation

enum LiveSubtitleSourceMode: String, CaseIterable, Identifiable {
    case systemAudioOnly
    case includeMicrophone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemAudioOnly:
            L10n.systemAudioOnly
        case .includeMicrophone:
            L10n.includeMicrophone
        }
    }

    func includesSpeakerLabel(_ speakerLabel: String?) -> Bool {
        switch self {
        case .systemAudioOnly:
            speakerLabel == "system"
        case .includeMicrophone:
            speakerLabel == nil || speakerLabel == "system" || speakerLabel == "mic"
        }
    }
}
