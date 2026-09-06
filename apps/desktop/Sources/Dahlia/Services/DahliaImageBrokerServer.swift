import DahliaRuntimeSupport
import Darwin
import Foundation
import GRDB
import Synchronization

/// POSIX I/O uses private threads; the mutex owns descriptors and the two-client bound.
/// Image requests have a separate socket so they cannot delay the token broker.
final class DahliaImageBrokerServer: Sendable {
    typealias Resolver = @Sendable (DahliaImageBrokerProtocol.Request) async throws -> Data
    private struct State {
        var listener: Int32?
        var socketURL: URL?
        var clients: Set<Int32> = []
        var tasks: [Int32: Task<Void, Never>] = [:]
    }

    private let state = Mutex(State())
    private let helperURL: URL
    private let resolver: Resolver

    init(helperURL: URL = DahliaMCPBundle.expectedExecutableURL(), resolver: @escaping Resolver) {
        self.helperURL = helperURL.resolvingSymlinksInPath()
        self.resolver = resolver
    }

    convenience init(dbQueue: DatabaseQueue, helperURL: URL = DahliaMCPBundle.expectedExecutableURL()) {
        self.init(helperURL: helperURL) { request in
            let matches = try await dbQueue.read { db in
                try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM screenshots s JOIN meetings m ON m.id = s.meetingId
                WHERE s.id = ? AND s.meetingId = ? AND m.vaultId = ?)
                """, arguments: [request.screenshotId, request.meetingId, request.vaultId]) ?? false
            }
            guard matches else { throw ScreenshotContentError.deleted }
            return try await ScreenshotContentProvider.shared.content(id: request.screenshotId, dbQueue: dbQueue).data
        }
    }

    func start(socketURL: URL = DahliaImageBrokerProtocol.socketURL()) throws {
        guard state.withLock({ $0.listener == nil }) else { return }
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(at: socketURL)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address: sockaddr_un
        do {
            address = try DahliaTokenBrokerProtocol.unixAddress(path: socketURL.path)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, DahliaTokenBrokerProtocol.unixAddressLength(path: socketURL.path))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 4) == 0, chmod(socketURL.path, 0o600) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        state.withLock { $0.listener = descriptor
            $0.socketURL = socketURL
        }
        Thread { [weak self] in self?.acceptLoop(descriptor) }.start()
    }

    func stop() {
        let stopped = state.withLock { value -> State in
            let old = value
            value.listener = nil
            value.socketURL = nil
            value.tasks = [:]
            return old
        }
        if let descriptor = stopped.listener {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        for task in stopped.tasks.values {
            task.cancel()
        }
        for client in stopped.clients {
            Darwin.shutdown(client, SHUT_RDWR)
        }
        if let socketURL = stopped.socketURL { try? FileManager.default.removeItem(at: socketURL) }
    }

    private func acceptLoop(_ listener: Int32) {
        while state.withLock({ $0.listener == listener }) {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { continue }
            let admitted = state.withLock { value in
                guard value.listener == listener, value.clients.count < 2 else { return false }
                value.clients.insert(client)
                return true
            }
            guard admitted else { Darwin.close(client)
                continue
            }
            Thread { [self] in
                defer {
                    _ = state.withLock { $0.clients.remove(client) }
                    Darwin.close(client)
                }
                handle(client)
            }.start()
        }
    }

    private func handle(_ descriptor: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid(),
              DahliaTokenBrokerAuthorization.resolveClient(descriptor: descriptor)?.executableURL.resolvingSymlinksInPath() == helperURL
        else { return }
        do {
            try DahliaImageBrokerProtocol.configure(descriptor, timeout: 2)
            let request = try JSONDecoder().decode(
                DahliaImageBrokerProtocol.Request.self,
                from: DahliaTokenBrokerProtocol.readLine(from: descriptor)
            )
            let result = Mutex<Result<Data, any Error>?>(nil)
            let semaphore = DispatchSemaphore(value: 0)
            let task = Task { [resolver] in
                do { let data = try await resolver(request)
                    result.withLock { $0 = .success(data) }
                } catch { result.withLock { $0 = .failure(error) } }
                semaphore.signal()
            }
            let running = state.withLock { value in
                guard value.listener != nil else { return false }
                value.tasks[descriptor] = task
                return true
            }
            defer { _ = state.withLock { $0.tasks.removeValue(forKey: descriptor) } }
            guard running else { task.cancel()
                return
            }
            guard semaphore.wait(timeout: .now() + .seconds(30)) == .success else {
                task.cancel()
                throw ScreenshotContentError.unavailable
            }
            guard let resolution = result.withLock({ $0 }) else { throw ScreenshotContentError.unavailable }
            let data = try resolution.get()
            guard (1 ... 64 * 1024 * 1024).contains(data.count) else { throw ScreenshotContentError.integrityFailure }
            try sendHeader(.init(byteCount: data.count), to: descriptor)
            try DahliaTokenBrokerProtocol.writeAll(data, to: descriptor)
        } catch {
            try? sendHeader(.init(byteCount: 0, error: "image_unavailable"), to: descriptor)
        }
    }

    private func sendHeader(_ response: DahliaImageBrokerProtocol.Response, to descriptor: Int32) throws {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        try DahliaTokenBrokerProtocol.writeAll(data, to: descriptor)
    }

    deinit { stop() }
}
