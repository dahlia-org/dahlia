import GRDB
import SwiftUI
import WebKit

@MainActor @Observable
final class DocumentEditorModel {
    // Keep failed/uncommitted input alive when the view is replaced. Only local commits are drained.
    private static var retained: [UUID: DocumentEditorModel] = [:]
    private static var removals: [UUID: (database: ObjectIdentifier, meetings: Set<UUID>, workspace: UUID?)] = [:]
    private let sessionID = UUID.v7()
    private var visible = false
    private var loadGeneration = 0
    static func activeMeetingIDs(dbQueue: DatabaseQueue) -> Set<UUID> {
        Set(retained.values.filter { $0.dbQueue === dbQueue }.map(\.documentID))
    }

    /// A logical lease spans the asynchronous deletion transaction without holding a lock.
    /// Open or failed editors defer deletion; a newly opened editor cannot race a reserved deletion.
    static func reserveRemoval(meetingIDs: Set<UUID>, dbQueue: DatabaseQueue, workspaceID: UUID? = nil) -> UUID? {
        guard activeMeetingIDs(dbQueue: dbQueue).isDisjoint(with: meetingIDs) else { return nil }
        if let workspaceID, retained.values.contains(where: { $0.dbQueue === dbQueue && $0.orphan?.workspaceID == workspaceID }) { return nil }
        let token = UUID.v7()
        removals[token] = (ObjectIdentifier(dbQueue), meetingIDs, workspaceID)
        return token
    }

    static func releaseRemoval(_ token: UUID) { removals[token] = nil }

    static func finishLocalSaves(dbQueue: DatabaseQueue? = nil, meetingID: UUID? = nil) async throws {
        for model in Array(retained.values)
            where (dbQueue == nil || model.dbQueue === dbQueue) && (meetingID == nil || model.documentID == meetingID) {
            try await model.finishLocalSaves()
        }
    }

    var checkpoint = ""
    var receivedUpdate = ""
    var status = ""
    var error = ""
    var legacyText = ""
    var recoveries: [DocumentRecoveryRecord] = []
    var people: [String] = []
    var recoveryText: [UUID: String] = [:]
    var ready = false
    private let persistence: DocumentPersistence
    private let sync: DocumentSyncService
    private let dbQueue: DatabaseQueue
    private let documentID: UUID
    private let orphan: DocumentPersistence.OrphanContext?
    private var preservingOrphan = false
    var flushEditor: (@MainActor () async throws -> Void)?
    private var saveTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var failedUpdates: [String] = []
    private(set) var meetingID: UUID?
    var resolveMeeting: @MainActor () -> UUID?

    init(
        dbQueue: DatabaseQueue,
        meetingID: UUID?,
        orphan: DocumentPersistence.OrphanContext? = nil,
        resolveMeeting: @escaping @MainActor () -> UUID?
    ) {
        self.dbQueue = dbQueue
        self.meetingID = meetingID
        self.orphan = orphan
        documentID = meetingID ?? orphan?.meetingID ?? .v7()
        self.resolveMeeting = resolveMeeting
        persistence = DocumentPersistence(dbQueue: dbQueue)
        sync = DocumentSyncService(dbQueue: dbQueue)
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        syncTask?.cancel()
        syncTask = nil
        ready = false
        visible = true
        do {
            if Self.removals.values.contains(where: {
                $0
                    .database == ObjectIdentifier(dbQueue) &&
                    ($0.meetings.contains(documentID) || ($0.workspace != nil && $0.workspace == orphan?.workspaceID))
            }) {
                throw DocumentCoreError.unavailable
            }
            Self.retained[sessionID] = self
            if let meetingID {
                let legacy = try await readLegacyText(meetingID: meetingID)
                guard isVisible(generation) else { return }
                legacyText = legacy
            }
            try await Self.finishLocalSaves(dbQueue: dbQueue, meetingID: meetingID)
            guard isVisible(generation) else { return }
            if let meetingID {
                let resident = try await dbQueue.read { try DocumentRecord.fetchOne($0, key: meetingID)?.resident ?? true }
                if !resident { try await sync.synchronize(meetingID: meetingID) }
                let prepared = try await persistence.prepare(meetingID: meetingID).checkpoint
                try await dbQueue.write { db in
                    try db.execute(sql: "UPDATE documents SET lastAccessedAt = ? WHERE id = ?", arguments: [Date(), meetingID])
                }
                let legacy = try await readLegacyText(meetingID: meetingID)
                guard isVisible(generation) else { return }
                checkpoint = prepared
                legacyText = legacy
            }
            await refreshRecoveries()
            guard isVisible(generation) else { return }
            ready = true
            syncTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.isVisible(generation) else { return }
                    guard let meetingID = self.meetingID else { continue }
                    do {
                        try await self.sync.synchronize(meetingID: meetingID)
                        let received = try await self.persistence.materialize(meetingID: meetingID).checkpoint
                        let pending = try await self.dbQueue.read { db in
                            try DocumentUpdateRecord.filter(Column("meetingId") == meetingID).filter(Column("pending") == true).fetchCount(db) > 0
                        }
                        let savedStatus = try await self.sync.target(meetingID: meetingID) == nil ? L10n.documentSavedLocally : L10n.documentSynced
                        guard self.isVisible(generation) else { return }
                        self.receivedUpdate = received
                        if !pending, self.failedUpdates.isEmpty {
                            self.status = savedStatus
                        }
                        let people = try await self.sync.presence(meetingID: meetingID, sessionID: self.sessionID, editing: self.focused)
                        guard self.isVisible(generation) else { return }
                        self.people = people
                        if self.error != L10n.documentPrivateRecoverySaved { self.error = "" }
                        await self.refreshRecoveries()
                    } catch {
                        guard self.isVisible(generation) else { return }
                        self.error = L10n.documentSyncFailed
                    }
                }
            }
        } catch {
            if isVisible(generation) { self.error = L10n.documentSaveFailed }
        }
    }

    private func isVisible(_ generation: Int) -> Bool {
        visible && loadGeneration == generation && !Task.isCancelled
    }

    private func readLegacyText(meetingID: UUID) async throws -> String {
        try await dbQueue.read { db in
            let copies = try DocumentPrivateCopyRecord.filter(Column("meetingId") == meetingID).order(Column("updatedAt").desc).fetchAll(db)
            if !copies.isEmpty { return copies.map(\.text).joined(separator: "\n\n") }
            let imported = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM document_legacy_imports WHERE meetingId = ?)",
                arguments: [meetingID]
            ) ?? false
            return imported ? "" : try MeetingNoteRecord.fetchOne(db, key: meetingID)?.text ?? ""
        }
    }

    var editorCommand: (id: UUID, name: String)?
    var focused = false

    func accept(_ update: String) {
        if meetingID == nil, !preservingOrphan { meetingID = resolveMeeting() }
        if meetingID == nil { preservingOrphan = true }
        failedUpdates.append(update)
        enqueueSave()
    }

    private func enqueueSave() {
        let previous = saveTask
        status = L10n.documentSaving
        saveTask = Task {
            await previous?.value
            do {
                let meetingID = meetingID ?? documentID
                var savedPrivately = false
                while let next = failedUpdates.first {
                    do {
                        try await persistence.append(meetingID: meetingID, update: next, local: true, orphan: orphan, privateOnly: preservingOrphan)
                    } catch DocumentCoreError.editPreservedPrivately {
                        savedPrivately = true
                    }
                    failedUpdates.removeFirst()
                }
                status = L10n.documentSavedLocally
                error = savedPrivately ? L10n.documentPrivateRecoverySaved : ""
            } catch { self.error = L10n.documentSaveFailed }
        }
    }

    func finishLocalSaves() async throws {
        try await flushEditor?()
        await saveTask?.value
        if !failedUpdates.isEmpty {
            enqueueSave()
            await saveTask?.value
        }
        guard failedUpdates.isEmpty else { throw DocumentCoreError.failed }
        if !visible { Self.retained[sessionID] = nil }
    }

    func stop() {
        loadGeneration &+= 1
        visible = false
        focused = false
        syncTask?.cancel()
        syncTask = nil
        Task { try? await finishLocalSaves() }
    }

    func refreshRecoveries() async {
        guard let meetingID else { return }
        let generation = loadGeneration
        do {
            let loaded = try await persistence.recoveries(meetingID: meetingID)
            guard isVisible(generation) else { return }
            (recoveries, recoveryText) = loaded
        } catch {
            if isVisible(generation) { self.error = L10n.documentSaveFailed }
        }
    }

    func restore(_ recovery: DocumentRecoveryRecord) {
        guard let meetingID, let text = recoveryText[recovery.id] else { return }
        Task {
            do {
                try await persistence.insertRecoveredText(meetingID: meetingID, text: text)
                receivedUpdate = try await persistence.materialize(meetingID: meetingID).checkpoint
            } catch { self.error = L10n.documentSaveFailed }
        }
    }
}

struct DocumentEditorView: View {
    @State private var model: DocumentEditorModel
    let editable: Bool

    init(
        dbQueue: DatabaseQueue,
        meetingID: UUID?,
        orphan: DocumentPersistence.OrphanContext?,
        editable: Bool,
        resolveMeeting: @escaping @MainActor () -> UUID?
    ) {
        _model = State(initialValue: DocumentEditorModel(dbQueue: dbQueue, meetingID: meetingID, orphan: orphan, resolveMeeting: resolveMeeting))
        self.editable = editable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.legacyText.isEmpty {
                DisclosureGroup(L10n.documentPrivateLegacy) {
                    Text(model.legacyText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
            if !model.error.isEmpty { Text(model.error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if model.ready {
                if editable {
                    HStack {
                        Button(L10n.documentBold) { model.editorCommand = (.v7(), "bold") }
                        Button(L10n.documentHeading) { model.editorCommand = (.v7(), "heading") }
                        Button(L10n.documentList) { model.editorCommand = (.v7(), "list") }
                        Button(L10n.documentUndo) { model.editorCommand = (.v7(), "undo") }
                        Button(L10n.documentRedo) { model.editorCommand = (.v7(), "redo") }
                    }.buttonStyle(.borderless)
                }
                DocumentWebEditor(
                    checkpoint: model.checkpoint,
                    receivedUpdate: model.receivedUpdate,
                    editable: editable,
                    command: model.editorCommand,
                    onUpdate: model.accept,
                    onFocus: { model.focused = $0 && editable },
                    onAttachFlush: { model.flushEditor = $0 }
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !model.recoveries.isEmpty {
                DisclosureGroup(L10n.documentRecoveryTitle) {
                    ScrollView {
                        ForEach(model.recoveries, id: \.id) { recovery in
                            VStack(alignment: .leading) {
                                Text(model.recoveryText[recovery.id] ?? "").textSelection(.enabled)
                                if editable { Button(L10n.documentRestore) { model.restore(recovery) } }
                            }
                        }
                    }.frame(maxHeight: 160)
                }
            }
            if !model.people.isEmpty { Text(L10n.documentEditing + model.people.joined(separator: ", ")).font(.caption) }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.load() }
        .onDisappear {
            model.stop()

        }
    }
}

private struct DocumentWebEditor: NSViewRepresentable {
    let checkpoint: String
    let receivedUpdate: String
    let editable: Bool
    let command: (id: UUID, name: String)?
    let onUpdate: @MainActor (String) -> Void
    let onFocus: @MainActor (Bool) -> Void
    let onAttachFlush: @MainActor (@escaping @MainActor () async throws -> Void) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "document")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        let coordinator = context.coordinator
        onAttachFlush { [weak coordinator] in
            guard let coordinator, let view = coordinator.view else { return }
            try await coordinator.flush(view)
        }
        if let url = Bundle.module.url(forResource: "document-editor", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        Task {
            try? await coordinator.flush(view)
            view.configuration.userContentController.removeScriptMessageHandler(forName: "document")
            view.navigationDelegate = nil
        }
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: DocumentWebEditor
        weak var view: WKWebView?
        private var ready = false
        private var lastUpdate = ""
        private var lastCommand: UUID?
        private var flushing: Task<Void, Error>?

        init(parent: DocumentWebEditor) { self.parent = parent }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
            switch body["type"] {
            case "ready":
                ready = true
                view?.callAsyncJavaScript(
                    "window.dahliaDocument.open(checkpoint, editable)",
                    arguments: ["checkpoint": parent.checkpoint, "editable": parent.editable],
                    in: nil,
                    in: .page,
                    completionHandler: nil
                )
                update()
            case "update":
                if let update = body["update"] { parent.onUpdate(update) }
            case "focus": parent.onFocus(body["focused"] == "true")
            case "link":
                if let string = body["url"], let url = URL(string: string), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
            default: break
            }
        }

        func flush(_ view: WKWebView) async throws {
            guard ready else { return }
            if let flushing { return try await flushing.value }
            let task = Task {
                let value = try await view.callAsyncJavaScript("return window.dahliaDocument.drain()", arguments: [:], in: nil, contentWorld: .page)
                if let update = value as? String { parent.onUpdate(update) }
            }
            flushing = task
            defer { flushing = nil }
            try await task.value
        }

        func update() {
            guard ready else { return }
            view?.callAsyncJavaScript(
                "window.dahliaDocument.setEditable(editable)",
                arguments: ["editable": parent.editable],
                in: nil,
                in: .page,
                completionHandler: nil
            )
            if let command = parent.command, command.id != lastCommand {
                lastCommand = command.id
                view?.callAsyncJavaScript(
                    "window.dahliaDocument.command(name)",
                    arguments: ["name": command.name],
                    in: nil,
                    in: .page,
                    completionHandler: nil
                )
            }
            guard !parent.receivedUpdate.isEmpty, parent.receivedUpdate != lastUpdate else { return }
            lastUpdate = parent.receivedUpdate
            view?.callAsyncJavaScript(
                "window.dahliaDocument.receive(update)",
                arguments: ["update": parent.receivedUpdate],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }

        func webView(
            _: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(action.navigationType == .other && action.request.url?.lastPathComponent == "document-editor.html" ? .allow : .cancel)
        }
    }
}
