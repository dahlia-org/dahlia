import CoreServices
import Foundation
import GRDB

/// `_dahlia/transcripts/` ディレクトリを FSEvents で監視する。
final class TranscriptFileWatcher: Sendable {
    let dbQueue: DatabaseQueue
    private let vaultURL: URL
    private nonisolated(unsafe) var streamRef: FSEventStreamRef?
    private let callbackQueue = DispatchQueue(label: "com.dahlia.transcript-file-watcher", qos: .utility)

    init(dbQueue: DatabaseQueue, vaultURL: URL) {
        self.dbQueue = dbQueue
        self.vaultURL = vaultURL
    }

    func startMonitoring() {
        stopMonitoring()

        let transcriptsDir = TranscriptExportService.transcriptsDirectoryURL(in: vaultURL)
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

        let pathsToWatch = [transcriptsDir.path as CFString] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            transcriptFileWatcherCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, callbackQueue)
        FSEventStreamStart(stream)
    }

    func stopMonitoring() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    deinit {
        stopMonitoring()
    }

    fileprivate func handleFileSystemEvent() {
        // 将来の拡張用: ファイル変更イベントのハンドリング
    }
}

// MARK: - FSEvents C コールバック

private func transcriptFileWatcherCallback(
    streamRef _: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths _: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds _: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallBackInfo else { return }
    let watcher = Unmanaged<TranscriptFileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    for i in 0 ..< numEvents {
        if eventFlags[i] & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
            watcher.handleFileSystemEvent()
            return
        }
    }
}
