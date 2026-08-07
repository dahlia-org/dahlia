import Combine
import Foundation

@MainActor
final class SpeakerModelSettingsViewModel: ObservableObject {
    enum State: Equatable {
        case checking
        case unavailable(managedByteCount: Int64)
        case acquiring(SpeakerModelAssetProgress)
        case available(managedByteCount: Int64)
        case failed(managedByteCount: Int64)
    }

    @Published private(set) var state: State = .checking

    private let assetManager: SpeakerModelAssetManager?
    private var acquisitionTask: Task<Void, Never>?

    init(assetManager: SpeakerModelAssetManager? = try? SpeakerModelAssetManager()) {
        self.assetManager = assetManager
    }

    var isAcquiring: Bool {
        if case .acquiring = state { true } else { false }
    }

    func inspect(settings: AppSettings) async {
        guard acquisitionTask == nil else { return }
        guard let assetManager else {
            settings.speakerIdentificationEnabled = false
            state = .failed(managedByteCount: 0)
            return
        }
        do {
            _ = try await assetManager.verifiedRevisionRootURL()
            let managedByteCount = try await assetManager.onDiskUsage()
            state = .available(managedByteCount: managedByteCount)
        } catch {
            settings.speakerIdentificationEnabled = false
            let managedByteCount = try? await assetManager.onDiskUsage()
            state = .unavailable(managedByteCount: managedByteCount ?? 0)
        }
    }

    func setEnabled(_ enabled: Bool, settings: AppSettings) {
        if enabled {
            acquire(settings: settings)
        } else {
            acquisitionTask?.cancel()
            acquisitionTask = nil
            settings.speakerIdentificationEnabled = false
        }
    }

    func acquire(settings: AppSettings) {
        guard acquisitionTask == nil, let assetManager else {
            settings.speakerIdentificationEnabled = false
            state = .failed(managedByteCount: 0)
            return
        }
        settings.speakerIdentificationEnabled = false
        state = .acquiring(.init(completedByteCount: 0, totalByteCount: 1, currentFile: nil))
        acquisitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await assetManager.acquire { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isAcquiring else { return }
                        self.state = .acquiring(progress)
                    }
                }
                try Task.checkCancellation()
                let byteCount = try await assetManager.onDiskUsage()
                settings.speakerIdentificationEnabled = true
                state = .available(managedByteCount: byteCount)
            } catch is CancellationError {
                settings.speakerIdentificationEnabled = false
                let managedByteCount = try? await assetManager.onDiskUsage()
                state = .unavailable(managedByteCount: managedByteCount ?? 0)
            } catch {
                settings.speakerIdentificationEnabled = false
                let managedByteCount = try? await assetManager.onDiskUsage()
                state = .failed(managedByteCount: managedByteCount ?? 0)
            }
            acquisitionTask = nil
        }
    }
}
