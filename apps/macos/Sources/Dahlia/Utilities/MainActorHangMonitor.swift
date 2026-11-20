import AppKit
import Foundation
import os

/// MainActor の応答停止を測る。スタックを取らず、他のスレッドを一時停止しない。
///
/// 専用スレッドが main queue へ短い block を送り、その実行までの遅れを停止時間とする。
/// 50 ms 以上は OSLog、250 ms 以上は匿名の固定タグだけで Sentry へ送る。スタックが必要な深刻な停止は、
/// Sentry SDK 既定の app hang 検出（2 秒）が担当し、`hangContext()` のタグが付く。
final class MainActorHangMonitor: Sendable {
    /// 停止直前にユーザーが見ていた画面。`mark(_:)` で更新し、停止開始の 2 秒前以降の印だけを使う。
    enum Surface: String, Sendable {
        case sidebar
        case screenshots
        case transcript
        case liveSubtitle
        case chat
        case other
    }

    struct State {
        var surface = Surface.other
        var markedAt: SuspendingClock.Instant?
        var isRecording = false
        var reported: Set<String> = []
    }

    static let shared = MainActorHangMonitor()

    static let logThresholdMilliseconds = 50
    static let reportThresholdMilliseconds = 250
    private static let pingInterval = Duration.milliseconds(50)
    private static let surfaceLifetime = Duration.seconds(2)
    private static let signposter = OSSignposter(subsystem: "com.dahlia", category: "Responsiveness")
    private static let logger = Logger(subsystem: ApplicationLogFile.subsystem, category: "MainActorHang")

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let started = OSAllocatedUnfairLock(initialState: false)

    func start() {
        guard started.withLock({ started in
            defer { started = true }
            return !started
        }) else { return }
        let thread = Thread { [self] in run() }
        thread.name = "com.dahlia.main-actor-hang-monitor"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// 画面の操作や更新の適用時に呼ぶ。lock 1 回だけの軽い処理。
    func mark(_ surface: Surface) {
        let now = SuspendingClock.now
        state.withLock {
            $0.surface = surface
            $0.markedAt = now
        }
    }

    func setRecording(_ isRecording: Bool) {
        state.withLock { $0.isRecording = isRecording }
    }

    /// 更新を適用する区間を Instruments で見える signpost にする。画面の印は付けない（非表示の画面にも更新は流れるため）。
    @MainActor
    func measure<T>(_ surface: Surface, _ body: () throws -> T) rethrows -> T {
        let interval = Self.signposter.beginInterval("ApplyUpdate", "\(surface.rawValue, privacy: .public)")
        defer { Self.signposter.endInterval("ApplyUpdate", interval) }
        return try body()
    }

    /// 要求から画面への反映までの時間を記録する（計測用。端末内の OSLog だけに残す）。
    func recordLatency(_ surface: Surface, since start: SuspendingClock.Instant) {
        let milliseconds = Int((SuspendingClock.now - start) / .milliseconds(1))
        Self.logger.info("latency surface=\(surface.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public)")
    }

    /// WebContent プロセスでの描画停止（応答なし、または終了）を送る。画面ごとに 1 回の起動で 1 度だけ。
    func reportWebStall(_ surface: Surface) {
        let (isRecording, isNew) = state.withLock { ($0.isRecording, $0.reported.insert("web.\(surface.rawValue)").inserted) }
        Self.logger.info("web content stall surface=\(surface.rawValue, privacy: .public)")
        guard isNew else { return }
        var context = Self.context(surface: surface, isRecording: isRecording)
        context["source"] = "mainActorHang"
        context["hangProcess"] = "web"
        context["hangDuration"] = "2s"
        ErrorReportingService.captureMainActorHang(context: context)
    }

    /// Sentry の app hang event に付ける固定タグ。SDK の検出スレッドから呼ばれる。
    func hangContext() -> [String: String] {
        // SDK は 2 秒の停止を検出した時点で呼ぶので、停止開始はおよそ 2 秒前。
        let stallStart = SuspendingClock.now - .seconds(2)
        return state.withLock { state in
            Self.context(surface: Self.surface(in: state, stallStartedAt: stallStart), isRecording: state.isRecording)
        }
    }

    private func run() {
        let responses = OSAllocatedUnfairLock<(at: SuspendingClock.Instant, isActive: Bool)?>(initialState: nil)
        while true {
            let sentAt = SuspendingClock.now
            responses.withLock { $0 = nil }
            DispatchQueue.main.async {
                let isActive = MainActor.assumeIsolated { NSApplication.shared.isActive }
                responses.withLock { $0 = (SuspendingClock.now, isActive) }
            }
            var response: (at: SuspendingClock.Instant, isActive: Bool)?
            repeat {
                Thread.sleep(forTimeInterval: Self.seconds(Self.pingInterval))
                response = responses.withLock { $0 }
            } while response == nil
            guard let response else {
                continue
            }
            record(stall: response.at - sentAt, startedAt: sentAt, appWasActive: response.isActive)
        }
    }

    private func record(stall: Duration, startedAt: SuspendingClock.Instant, appWasActive: Bool) {
        let milliseconds = Int(stall / .milliseconds(1))
        guard milliseconds >= Self.logThresholdMilliseconds else { return }
        let (surface, isRecording, shouldReport) = state.withLock { state in
            let surface = Self.surface(in: state, stallStartedAt: startedAt)
            let bucket = Self.durationBucket(milliseconds: milliseconds)
            // 前面にも録音中にもないアプリの遅れは、ユーザーが体感しない App Nap の可能性があるので送らない。
            guard let bucket, appWasActive || state.isRecording else { return (surface, state.isRecording, false) }
            let isNew = state.reported.insert("\(surface.rawValue).\(bucket)").inserted
            return (surface, state.isRecording, isNew)
        }
        Self.signposter.emitEvent("MainActorStall", "\(surface.rawValue, privacy: .public) \(milliseconds, privacy: .public)ms")
        Self.logger.info(
            "main actor stall ms=\(milliseconds, privacy: .public) surface=\(surface.rawValue, privacy: .public) recording=\(isRecording, privacy: .public)"
        )
        guard shouldReport, let bucket = Self.durationBucket(milliseconds: milliseconds) else { return }
        var context = Self.context(surface: surface, isRecording: isRecording)
        context["source"] = "mainActorHang"
        context["hangDuration"] = bucket
        ErrorReportingService.captureMainActorHang(context: context)
    }

    static func surface(in state: State, stallStartedAt start: SuspendingClock.Instant) -> Surface {
        guard let markedAt = state.markedAt, markedAt >= start - surfaceLifetime else { return .other }
        return state.surface
    }

    static func context(surface: Surface, isRecording: Bool) -> [String: String] {
        ["hangSurface": surface.rawValue, "recording": isRecording ? "active" : "idle", "hangProcess": "app"]
    }

    /// 250 ms 未満は Sentry へ送らないので nil。
    static func durationBucket(milliseconds: Int) -> String? {
        switch milliseconds {
        case ..<reportThresholdMilliseconds: nil
        case ..<500: "250ms"
        case ..<1000: "500ms"
        case ..<2000: "1s"
        case ..<5000: "2s"
        default: "5sPlus"
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
