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
final class SystemAppPermissionProvider: AppPermissionProviding {
    private let calendarStore: MacCalendarStore

    init(calendarStore: MacCalendarStore = .shared) {
        self.calendarStore = calendarStore
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
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            return microphoneStatus()
        case .calendar:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                await calendarStore.requestAuthorizationOnly()
            }
            return calendarStatus()
        }
    }

    private func screenCaptureStatus() -> AppPermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        // CoreGraphics exposes only a Boolean preflight result, so a false value
        // cannot reliably distinguish an initial request from a previous denial.
        return .requiresReview
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
