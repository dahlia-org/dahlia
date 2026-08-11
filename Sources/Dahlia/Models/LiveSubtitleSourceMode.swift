enum LiveSubtitleSourceMode: String {
    case systemAudioOnly
    case includeMicrophone

    static let defaultMode: Self = .systemAudioOnly

    init(storedRawValue: String) {
        self = Self(rawValue: storedRawValue) ?? .defaultMode
    }

    init(includesMicrophone: Bool) {
        self = includesMicrophone ? .includeMicrophone : .systemAudioOnly
    }

    var includesMicrophone: Bool {
        self == .includeMicrophone
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
