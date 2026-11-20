import SwiftUI
import WebKit

/// 文字起こしの行を WebContent プロセスで描画する。描画が重くてもアプリの MainActor は止まらない。
///
/// `TranscriptStore` の表示範囲をそのまま写し、前回送った内容との差分だけを送る。送信は 1 件ずつで、Web から
/// `presented`（その更新を描いたフレーム）が届くまで次を送らない。待つ間の変更は次の差分にまとまるので、未送信が積み上がらない。
/// 表示中に 2 秒返らないか WebContent が落ちたら、読み込み直して全行を送り直す。
struct TranscriptWebSurface: NSViewRepresentable {
    enum Edge: String {
        case top
        case bottom
    }

    /// 表示範囲の持ち主が変わったら（Meeting の切り替え、再文字起こし）全行を送り直す。
    let contentID: AnyHashable
    let segments: [TranscriptSegment]
    let recordingSessions: [RecordingSessionTimeline]
    let timeBase: Date
    let showsTranslatedText: Bool
    let hasEarlier: Bool
    let hasLater: Bool
    /// `token` が変わるたびに一度だけ `edge` へスクロールする。
    let scrollRequest: (token: Int, edge: Edge)?
    let onRequestPage: @MainActor (Edge) -> Void
    let onFollowChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "transcript")
        configuration.userContentController.addUserScript(WKUserScript(source: """
        document.documentElement.style.setProperty('--base', '\(DahliaTypography.baseSize)px');
        document.documentElement.style.setProperty('--inset', '\(DahliaDesign.tabContentInset)px');
        document.documentElement.style.setProperty('--max-width', '\(DahliaDesign.mainContentMaxWidth)px');
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        context.coordinator.load()
        return view
    }

    func updateNSView(_: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.contentDidChange()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "transcript")
        view.navigationDelegate = nil
    }

    struct Row: Equatable {
        let id: String
        let time: String
        let text: String
        let translation: String?
        let speaker: String?
        let speakerColor: String?
        let confirmed: Bool

        var message: [String: Any] {
            var message: [String: Any] = ["id": id, "time": time, "text": text, "confirmed": confirmed]
            message["translation"] = translation
            message["speaker"] = speaker
            message["speakerColor"] = speakerColor
            return message
        }
    }

    @MainActor static func row(
        _ segment: TranscriptSegment,
        sessions: [RecordingSessionTimeline],
        timeBase: Date,
        showsTranslatedText: Bool
    ) -> Row {
        Row(
            id: segment.id.uuidString,
            time: Formatters.elapsedHHmmss(at: segment.startTime, sessionId: segment.sessionId, sessions: sessions, fallbackTimeBase: timeBase),
            text: segment.displayText,
            translation: segment.visibleTranslatedText(isEnabled: showsTranslatedText),
            speaker: segment.speakerLabel.map(speakerName),
            speakerColor: segment.speakerLabel.map(speakerColor),
            confirmed: segment.isConfirmed
        )
    }

    @MainActor private static func speakerName(_ label: String) -> String {
        switch label {
        case "mic": L10n.mic
        case "system": L10n.system
        default: label
        }
    }

    private static func speakerColor(_ label: String) -> String {
        let colors = ["blue", "orange", "green", "purple", "pink", "teal", "indigo", "brown"]
        let index = switch label {
        case "mic": 0
        case "system": 1
        default: ["A", "B", "C", "D", "E", "F", "G", "H"].firstIndex(of: label.replacingOccurrences(of: "話者", with: ""))
            ?? ((Int(label.replacingOccurrences(of: "話者", with: "")) ?? 1) - 1)
        }
        return "-apple-system-\(colors[((index % colors.count) + colors.count) % colors.count])"
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: TranscriptWebSurface
        weak var view: WKWebView?
        private var isReady = false
        private var sequence = 0
        private var inFlight: (sequence: Int, changedAt: SuspendingClock.Instant)?
        private var sentRows: [String: Row] = [:]
        private var sentOrder: [String] = []
        private var sentContentID: AnyHashable?
        private var sentEdges: (hasEarlier: Bool, hasLater: Bool)?
        private var sentScrollToken: Int?
        private var changedAt: SuspendingClock.Instant?
        private var timeout: Task<Void, Never>?
        /// Tests shorten the wait and treat an offscreen window as displayed.
        var responseTimeout = Duration.seconds(2)
        lazy var isDisplayed: @MainActor () -> Bool = { [weak self] in
            self?.view?.window?.occlusionState.contains(.visible) == true
        }

        init(parent: TranscriptWebSurface) {
            self.parent = parent
        }

        func load() {
            guard let view, let url = Bundle.appModule.url(forResource: "transcript-surface", withExtension: "html") else { return }
            isReady = false
            inFlight = nil
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func stop() {
            timeout?.cancel()
            timeout = nil
        }

        func contentDidChange() {
            if changedAt == nil { changedAt = .now }
            send()
        }

        private func send() {
            guard isReady, inFlight == nil, let view else { return }
            let parent = parent
            let reset = sentContentID != parent.contentID
            if reset {
                sentRows.removeAll()
                sentOrder.removeAll()
            }
            let rows = parent.segments.map {
                TranscriptWebSurface.row(
                    $0,
                    sessions: parent.recordingSessions,
                    timeBase: parent.timeBase,
                    showsTranslatedText: parent.showsTranslatedText
                )
            }
            let changed = rows.filter { sentRows[$0.id] != $0 }
            let order = rows.map(\.id)
            let edges = (hasEarlier: parent.hasEarlier, hasLater: parent.hasLater)
            let scroll = parent.scrollRequest.flatMap { $0.token == sentScrollToken ? nil : $0 }
            guard reset || !changed.isEmpty || order != sentOrder || sentEdges.map({ $0 != edges }) ?? true || scroll != nil else {
                changedAt = nil
                return
            }

            sequence += 1
            var update: [String: Any] = [
                "seq": sequence,
                "reset": reset,
                "order": order,
                "rows": changed.map(\.message),
                "hasEarlier": edges.hasEarlier,
                "hasLater": edges.hasLater,
            ]
            update["scrollTo"] = scroll?.edge.rawValue
            for row in changed {
                sentRows[row.id] = row
            }
            let kept = Set(order)
            for id in sentOrder where !kept.contains(id) {
                sentRows[id] = nil
            }
            sentOrder = order
            sentContentID = parent.contentID
            sentEdges = edges
            sentScrollToken = parent.scrollRequest?.token ?? sentScrollToken
            inFlight = (sequence, changedAt ?? .now)
            changedAt = nil

            MainActorHangMonitor.shared.measure(.transcript) {
                view.callAsyncJavaScript(
                    "window.dahliaTranscript.apply(update)", arguments: ["update": update], in: nil, in: .page
                ) { [weak self] result in
                    if case .failure = result { self?.recover() }
                }
            }
            armTimeout(for: sequence)
        }

        /// 隠れたウィンドウは描画しないので、見えている間だけ応答を待つ。
        private func armTimeout(for sequence: Int) {
            timeout?.cancel()
            timeout = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, inFlight?.sequence == sequence {
                    try? await Task.sleep(for: responseTimeout)
                    guard !Task.isCancelled, inFlight?.sequence == sequence else { return }
                    guard isDisplayed() else { continue }
                    MainActorHangMonitor.shared.reportWebStall(.transcript)
                    recover()
                    return
                }
            }
        }

        /// 表示は SQLite から作り直せる projection なので、読み込み直して全行を送り直す。
        private func recover() {
            timeout?.cancel()
            sentContentID = nil
            sentScrollToken = nil
            load()
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                sentContentID = nil
                send()
            case "presented":
                guard let sequence = body["seq"] as? Int, let inFlight, inFlight.sequence == sequence else { return }
                MainActorHangMonitor.shared.recordLatency(.transcript, since: inFlight.changedAt)
                self.inFlight = nil
                timeout?.cancel()
                send()
            case "requestPage":
                MainActorHangMonitor.shared.mark(.transcript)
                if let direction = body["direction"] as? String {
                    parent.onRequestPage(direction == "earlier" ? .top : .bottom)
                }
            case "follow":
                parent.onFollowChange(body["following"] as? Bool ?? false)
            default:
                break
            }
        }

        func webViewWebContentProcessDidTerminate(_: WKWebView) {
            MainActorHangMonitor.shared.reportWebStall(.transcript)
            recover()
        }

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.isFileURL == true ? .allow : .cancel
        }
    }
}
