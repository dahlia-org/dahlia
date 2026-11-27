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
    var baseSize: CGFloat = DahliaTypography.defaultBaseSize
    var maxWidth = ContentWidth.mainDefault.maxWidth
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
        document.documentElement.style.setProperty('--inset', '\(DahliaDesign.tabContentInset)px');
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
        private var inFlight: (sequence: Int, changedAt: SuspendingClock.Instant, scrollToken: Int?)?
        private var needsReset = true
        private var viewport: Viewport?
        private var sentBaseSize: CGFloat?
        private var sentMaxWidth: CGFloat?
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

        private struct Viewport {
            let following: Bool
            let anchorID: String?
            let offset: Double

            var message: [String: Any] {
                var result: [String: Any] = ["following": following, "offset": offset]
                result["anchorID"] = anchorID
                return result
            }
        }

        init(parent: TranscriptWebSurface) {
            self.parent = parent
        }

        func load() {
            guard let view, let url = Bundle.appModule.url(forResource: "transcript-surface", withExtension: "html") else { return }
            isReady = false
            sentMaxWidth = nil
            needsReset = true
            inFlight = nil
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func stop() {
            timeout?.cancel()
            timeout = nil
        }

        func contentDidChange() {
            if changedAt == nil { changedAt = .now }
            applyMaxWidth()
            send()
        }

        private func applyMaxWidth() {
            guard isReady, let view, sentMaxWidth != parent.maxWidth else { return }
            sentMaxWidth = parent.maxWidth
            let value = parent.maxWidth.isFinite ? "\(parent.maxWidth)px" : "none"
            view.callAsyncJavaScript(
                "document.documentElement.style.setProperty('--max-width', value)",
                arguments: ["value": value], in: nil, in: .page
            )
        }

        private func send() {
            guard isReady, inFlight == nil, let view else { return }
            let parent = parent
            let contentChanged = sentContentID != parent.contentID
            let reset = needsReset || contentChanged
            if contentChanged {
                viewport = nil
                sentScrollToken = nil
            }
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
            guard reset || !changed.isEmpty || order != sentOrder || sentEdges.map({ $0 != edges }) ?? true || scroll != nil || sentBaseSize != parent
                .baseSize else {
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
                "baseSize": parent.baseSize,
            ]
            update["scrollTo"] = scroll?.edge.rawValue
            if reset, scroll == nil { update["restoreViewport"] = viewport?.message }
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
            sentBaseSize = parent.baseSize
            needsReset = false
            inFlight = (sequence, changedAt ?? .now, scroll?.token)
            changedAt = nil

            MainActorHangMonitor.shared.measure(.transcript) {
                view.callAsyncJavaScript(
                    "window.dahliaTranscript.apply(update)", arguments: ["update": update], in: nil, in: .page
                ) { [weak self, sequence] result in
                    guard let self, self.inFlight?.sequence == sequence else { return }
                    if case .failure = result { self.recover() }
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
            load()
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                needsReset = true
                applyMaxWidth()
                send()
            case "presented":
                guard let sequence = body["seq"] as? Int, let inFlight, inFlight.sequence == sequence else { return }
                MainActorHangMonitor.shared.recordLatency(.transcript, since: inFlight.changedAt)
                sentScrollToken = inFlight.scrollToken ?? sentScrollToken
                self.inFlight = nil
                timeout?.cancel()
                send()
            case "requestPage":
                MainActorHangMonitor.shared.mark(.transcript)
                if let direction = body["direction"] as? String {
                    parent.onRequestPage(direction == "earlier" ? .top : .bottom)
                }
            case "viewport":
                guard isReady, body["seq"] as? Int == sequence, sentContentID == parent.contentID,
                      let following = body["following"] as? Bool else { return }
                let previous = viewport?.following
                viewport = Viewport(following: following, anchorID: body["anchorID"] as? String, offset: body["offset"] as? Double ?? 0)
                if previous != following { parent.onFollowChange(following) }
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
