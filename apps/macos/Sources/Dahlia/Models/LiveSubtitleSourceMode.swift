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

    func includesAudioSource(_ audioSource: String?) -> Bool {
        switch self {
        case .systemAudioOnly:
            audioSource == "system"
        case .includeMicrophone:
            audioSource == nil || audioSource == "system" || audioSource == "mic"
        }
    }
}
