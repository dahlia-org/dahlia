enum AppPermission: CaseIterable, Hashable, Identifiable {
    case screenAndSystemAudio
    case microphone
    case calendar

    var id: Self { self }

    var title: String {
        switch self {
        case .screenAndSystemAudio:
            L10n.screenAndSystemAudioPermission
        case .microphone:
            L10n.microphonePermission
        case .calendar:
            L10n.calendarPermission
        }
    }

    var description: String {
        switch self {
        case .screenAndSystemAudio:
            L10n.screenAndSystemAudioPermissionDescription
        case .microphone:
            L10n.microphonePermissionDescription
        case .calendar:
            L10n.calendarPermissionDescription
        }
    }

    var systemImage: String {
        switch self {
        case .screenAndSystemAudio:
            "speaker.wave.2"
        case .microphone:
            "mic"
        case .calendar:
            "calendar"
        }
    }

    var footer: String? {
        switch self {
        case .screenAndSystemAudio:
            L10n.screenAndSystemAudioPermissionFooter
        case .microphone:
            nil
        case .calendar:
            L10n.calendarPermissionFooter
        }
    }
}

enum AppPermissionStatus: Equatable {
    case notDetermined
    case requiresReview
    case granted
    case denied
    case restricted

    var label: String {
        switch self {
        case .notDetermined:
            L10n.permissionNotDetermined
        case .requiresReview:
            L10n.permissionRequiresReview
        case .granted:
            L10n.permissionGranted
        case .denied:
            L10n.permissionDenied
        case .restricted:
            L10n.permissionRestricted
        }
    }

    var systemImage: String {
        switch self {
        case .notDetermined:
            "questionmark.circle"
        case .requiresReview:
            "eye.circle"
        case .granted:
            "checkmark.circle.fill"
        case .denied:
            "exclamationmark.triangle.fill"
        case .restricted:
            "lock.fill"
        }
    }
}

extension AppPermission {
    func guidance(for status: AppPermissionStatus) -> String? {
        switch status {
        case .notDetermined, .granted:
            nil
        case .requiresReview:
            L10n.screenCapturePermissionReviewGuidance
        case .denied:
            switch self {
            case .screenAndSystemAudio:
                L10n.screenCapturePermissionDeniedGuidance
            case .microphone:
                L10n.microphonePermissionDeniedGuidance
            case .calendar:
                L10n.calendarPermissionDeniedGuidance
            }
        case .restricted:
            L10n.permissionRestrictedGuidance
        }
    }
}
