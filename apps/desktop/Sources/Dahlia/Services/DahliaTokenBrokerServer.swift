import DahliaRuntimeSupport
import Darwin
import Foundation
import Synchronization

final class DahliaTokenBrokerAuthorization: Sendable {
    static let shared = DahliaTokenBrokerAuthorization()

    struct Client: Sendable {
        let executableURL: URL
        let parentPID: pid_t
    }

    typealias ClientResolver = @Sendable (Int32) -> Client?

    private struct Grant {
        let appServerPID: pid_t
        let connectionID: UUID
        let helperURL: URL
    }

    private let grants = Mutex<[String: Grant]>([:])
    private let clientResolver: ClientResolver

    init() {
        clientResolver = Self.resolveClient
    }

    init(clientResolver: @escaping ClientResolver) {
        self.clientResolver = clientResolver
    }

    func register(profile: DahliaRuntimeProfile, connectionID: UUID, appServerPID: pid_t, helperURL: URL) {
        grants.withLock {
            $0[profile.rawValue] = Grant(
                appServerPID: appServerPID,
                connectionID: connectionID,
                helperURL: helperURL.resolvingSymlinksInPath()
            )
        }
    }

    func authorizesClient(_ descriptor: Int32, profile: DahliaRuntimeProfile) -> Bool {
        guard let grant = grants.withLock({ $0[profile.rawValue] }),
              let client = clientResolver(descriptor)
        else { return false }
        return client.parentPID == grant.appServerPID
            && client.executableURL.resolvingSymlinksInPath() == grant.helperURL
    }

    func authorizesConnection(_ connectionID: UUID, profile: DahliaRuntimeProfile) -> Bool {
        grants.withLock { $0[profile.rawValue]?.connectionID == connectionID }
    }

    func clear(profile: DahliaRuntimeProfile) {
        _ = grants.withLock { $0.removeValue(forKey: profile.rawValue) }
    }

    private static func resolveClient(descriptor: Int32) -> Client? {
        var peerPID: pid_t = 0
        var peerPIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDLength) == 0 else { return nil }

        var info = proc_bsdinfo()
        guard proc_pidinfo(
            peerPID,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        ) == MemoryLayout<proc_bsdinfo>.size else { return nil }

        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        let pathLength = proc_pidpath(peerPID, &path, UInt32(path.count))
        guard pathLength > 0 else { return nil }
        return Client(
            executableURL: URL(filePath: String(
                decoding: path.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )),
            parentPID: pid_t(info.pbi_ppid)
        )
    }
}

/// POSIX accept/read/write are isolated to one private Thread. The lock protects its lifecycle state.
final class DahliaTokenBrokerServer: @unchecked Sendable {
    typealias TokenResolver = @Sendable (UUID) async throws -> String

    private struct State {
        var descriptor: Int32?
        var socketURL: URL?
        var profile: DahliaRuntimeProfile?
    }

    private enum Resolution: Sendable {
        case token(String)
        case error(String)
    }

    private let state = Mutex(State())
    private let authorization: DahliaTokenBrokerAuthorization
    private let tokenResolver: TokenResolver

    init(
        authorization: DahliaTokenBrokerAuthorization = .shared,
        tokenResolver: @escaping TokenResolver = { connectionID in
            try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: connectionID)
        }
    ) {
        self.authorization = authorization
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
            $0.profile = profile
        }
        Thread { [weak self] in self?.acceptLoop(descriptor: descriptor) }.start()
    }

    func stop() {
        let stopped = state.withLock { state -> (descriptor: Int32?, socketURL: URL?, profile: DahliaRuntimeProfile?) in
            let result = (state.descriptor, state.socketURL, state.profile)
            state.descriptor = nil
            state.socketURL = nil
            state.profile = nil
            return result
        }
        if let descriptor = stopped.descriptor { Darwin.close(descriptor) }
        if let socketURL = stopped.socketURL { try? FileManager.default.removeItem(at: socketURL) }
        if let profile = stopped.profile { authorization.clear(profile: profile) }
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
            guard let profile = state.withLock({ $0.profile }) else {
                Darwin.close(client)
                continue
            }
            var readTimeout = timeval(tv_sec: 1, tv_usec: 0)
            guard setsockopt(
                client,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &readTimeout,
                socklen_t(MemoryLayout.size(ofValue: readTimeout))
            ) == 0 else {
                Darwin.close(client)
                continue
            }
            handle(client, profile: profile)
            Darwin.close(client)
        }
    }

    private func handle(_ descriptor: Int32, profile: DahliaRuntimeProfile) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == getuid(),
              authorization.authorizesClient(descriptor, profile: profile)
        else { return }

        let response: DahliaTokenBrokerProtocol.Response
        do {
            let data = try DahliaTokenBrokerProtocol.readLine(from: descriptor)
            let request = try JSONDecoder().decode(DahliaTokenBrokerProtocol.Request.self, from: data)
            guard authorization.authorizesConnection(request.connectionID, profile: profile) else {
                throw POSIXError(.EACCES)
            }
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
