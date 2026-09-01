import DahliaRuntimeSupport
import Darwin
import Foundation
import Synchronization

/// POSIX accept/read/write are isolated to one private Thread. The lock protects its lifecycle state.
final class DahliaTokenBrokerServer: @unchecked Sendable {
    typealias TokenResolver = @Sendable (UUID) async throws -> String

    private struct State {
        var descriptor: Int32?
        var socketURL: URL?
    }

    private enum Resolution: Sendable {
        case token(String)
        case error(String)
    }

    private let state = Mutex(State())
    private let tokenResolver: TokenResolver

    init(tokenResolver: @escaping TokenResolver = { connectionID in
        try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: connectionID)
    }) {
        self.tokenResolver = tokenResolver
    }

    func start(
        profile: DahliaRuntimeProfile = DahliaApplicationSupport.profile(),
        applicationSupportDirectory: URL = .applicationSupportDirectory
    ) throws {
        guard state.withLock({ $0.descriptor == nil }) else { return }
        let socketURL = DahliaTokenBrokerProtocol.socketURL(
            profile: profile,
            applicationSupportDirectory: applicationSupportDirectory
        )
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(at: socketURL)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = try DahliaTokenBrokerProtocol.unixAddress(path: socketURL.path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, DahliaTokenBrokerProtocol.unixAddressLength(path: socketURL.path))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard chmod(socketURL.path, 0o600) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.init(rawValue: errno) ?? .EACCES)
        }
        state.withLock {
            $0.descriptor = descriptor
            $0.socketURL = socketURL
        }
        Thread { [weak self] in self?.acceptLoop(descriptor: descriptor) }.start()
    }

    func stop() {
        let stopped = state.withLock { state -> (descriptor: Int32?, socketURL: URL?) in
            let result = (state.descriptor, state.socketURL)
            state.descriptor = nil
            state.socketURL = nil
            return result
        }
        if let descriptor = stopped.descriptor { Darwin.close(descriptor) }
        if let socketURL = stopped.socketURL { try? FileManager.default.removeItem(at: socketURL) }
    }

    private func acceptLoop(descriptor: Int32) {
        while state.withLock({ $0.descriptor == descriptor }) {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            var noSignal: Int32 = 1
            guard setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout.size(ofValue: noSignal))
            ) == 0 else {
                Darwin.close(client)
                continue
            }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ descriptor: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == getuid() else { return }

        let response: DahliaTokenBrokerProtocol.Response
        do {
            let data = try DahliaTokenBrokerProtocol.readLine(from: descriptor)
            let request = try JSONDecoder().decode(DahliaTokenBrokerProtocol.Request.self, from: data)
            let result = Mutex<Resolution?>(nil)
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let token = try await tokenResolver(request.connectionID)
                    result.withLock { $0 = .token(token) }
                } catch {
                    result.withLock { $0 = .error(error.localizedDescription) }
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + .seconds(8)) == .success else {
                throw POSIXError(.ETIMEDOUT)
            }
            switch result.withLock({ $0 }) {
            case let .token(token): response = .init(token: token)
            case let .error(message): response = .init(error: message)
            case nil: response = .init(error: "Token broker failed")
            }
        } catch {
            response = .init(error: error.localizedDescription)
        }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        try? DahliaTokenBrokerProtocol.writeAll(data, to: descriptor)
    }

    deinit {
        stop()
    }
}
