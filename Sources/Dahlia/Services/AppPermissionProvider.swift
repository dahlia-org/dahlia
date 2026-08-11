@preconcurrency import AVFoundation
import CoreGraphics
@preconcurrency import EventKit
import Foundation

@MainActor
protocol AppPermissionProviding {
    func status(for permission: AppPermission) -> AppPermissionStatus
    func request(_ permission: AppPermission) async -> AppPermissionStatus
}

@MainActor
protocol CalendarPermissionRequesting {
    func requestFullAccess() async
}

@MainActor
final class EventKitCalendarPermissionRequester: CalendarPermissionRequesting {
    private let eventStore = EKEventStore()

    func requestFullAccess() async {
        _ = try? await eventStore.requestFullAccessToEvents()
    }
}

@MainActor
final class SystemAppPermissionProvider: AppPermissionProviding {
    private let calendarPermissionRequester: any CalendarPermissionRequesting
    private let preflightScreenCapture: () -> Bool
    private let requestScreenCapture: () -> Bool
    private var screenCaptureDeniedInSession = false

    init(
        calendarPermissionRequester: any CalendarPermissionRequesting = EventKitCalendarPermissionRequester(),
        preflightScreenCapture: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
        requestScreenCapture: @escaping () -> Bool = CGRequestScreenCaptureAccess
    ) {
        self.calendarPermissionRequester = calendarPermissionRequester
        self.preflightScreenCapture = preflightScreenCapture
        self.requestScreenCapture = requestScreenCapture
    }

    func status(for permission: AppPermission) -> AppPermissionStatus {
        switch permission {
        case .screenAndSystemAudio:
            screenCaptureStatus()
        case .microphone:
            microphoneStatus()
        case .calendar:
            calendarStatus()
        }
    }

    func request(_ permission: AppPermission) async -> AppPermissionStatus {
        switch permission {
        case .screenAndSystemAudio:
            let granted = requestScreenCapture()
            screenCaptureDeniedInSession = !granted
            return granted ? .granted : .denied
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            return microphoneStatus()
        case .calendar:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                await calendarPermissionRequester.requestFullAccess()
            }
            return calendarStatus()
        }
    }

    private func screenCaptureStatus() -> AppPermissionStatus {
        if preflightScreenCapture() {
            screenCaptureDeniedInSession = false
            return .granted
        }
        // CoreGraphics exposes only a Boolean preflight result, so a false value
        // cannot reliably distinguish an initial request from a previous denial.
        return screenCaptureDeniedInSession ? .denied : .requiresReview
    }

    private func microphoneStatus() -> AppPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notDetermined
        case .authorized:
            .granted
        case .denied:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .restricted
        }
    }

    private func calendarStatus() -> AppPermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            .notDetermined
        case .fullAccess:
            .granted
        case .denied, .writeOnly:
            .denied
        case .restricted:
            .restricted
        @unknown default:
            .restricted
        }
    }
}
