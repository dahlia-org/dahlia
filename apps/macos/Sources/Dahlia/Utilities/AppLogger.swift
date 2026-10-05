import DahliaRuntimeSupport
import Foundation
import os

/// `Logger` と同じ行を `ApplicationLogFile` にも書き、前回プロセスのログも診断に使えるようにする。
/// メッセージは公開値としてそのまま残るため、本文・識別子・資格情報を含めない。
/// 高頻度の計測はファイルに残さず `Logger.debug` を直接使う。
struct AppLogger: Sendable {
    enum Level: String, Sendable {
        case info = "INFO"
        case notice = "NOTICE"
        case error = "ERROR"

        var osLogType: OSLogType {
            switch self {
            case .info: .info
            case .notice: .default
            case .error: .error
            }
        }
    }

    private let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: ApplicationLogFile.subsystem, category: category)
    }

    func info(_ message: String) {
        log(message, level: .info)
    }

    func notice(_ message: String) {
        log(message, level: .notice)
    }

    func error(_ message: String) {
        log(message, level: .error)
    }

    static func fields(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    func log(_ message: String, level: Level) {
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
        ApplicationLogFile.shared.append(message, level: level, category: category)
    }
}

/// 一定サイズでローテーションするアプリログ。`start()` 前の行は OSLog にだけ残る。
/// 書き込みは呼び出し元をブロックしない専用 serial queue で直列化し、可変状態もこの queue に閉じる。
final class ApplicationLogFile: @unchecked Sendable {
    static let subsystem = "com.dahlia"
    /// DB とプロセスロックと同じプロファイルに置き、worktree ごとの開発版が同じファイルを回さないようにする。
    static let shared = ApplicationLogFile(
        directoryURL: DahliaApplicationSupport.currentDirectoryURL.appending(path: "Logs", directoryHint: .isDirectory)
    )

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current)

    private let directoryURL: URL
    private let maximumFileBytes: Int
    private let maximumFileCount: Int
    private let queue = DispatchQueue(label: "com.dahlia.application-log-file", qos: .utility)
    private var isEnabled = false
    private var handle: FileHandle?
    private var fileBytes = 0

    // ponytail: 1 MiB × 10 世代で頭打ち。数日分で足りなくなったら増やす。
    init(directoryURL: URL, maximumFileBytes: Int = 1 << 20, maximumFileCount: Int = 10) {
        self.directoryURL = directoryURL
        self.maximumFileBytes = maximumFileBytes
        self.maximumFileCount = maximumFileCount
    }

    /// DB を所有するアプリ本体だけが呼ぶ。テストやプレビューではファイルに書かない。
    func start() {
        queue.async { [self] in
            isEnabled = true
        }
    }

    func append(_ message: String, level: AppLogger.Level, category: String) {
        let date = Date.now
        queue.async { [self] in
            guard isEnabled else { return }
            let message = message.split(whereSeparator: \.isNewline).joined(separator: " ")
            write("\(date.formatted(Self.timestampStyle)) [\(level.rawValue)] [\(category)] \(message)\n")
        }
    }

    /// 前回以前のプロセスを含む直近 `limit` 行を古い順に返す。
    func recentLines(limit: Int) async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var lines: [String] = []
                for index in 0 ..< maximumFileCount where lines.count < limit {
                    // 書き込み途中で終了した行の壊れた UTF-8 でファイル全体を捨てないよう、置換文字で読む。
                    guard let data = try? Data(contentsOf: fileURL(index)) else { continue }
                    lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) + lines
                }
                continuation.resume(returning: Array(lines.suffix(limit)))
            }
        }
    }

    private func write(_ line: String) {
        let data = Data(line.utf8)
        do {
            if handle == nil {
                try open()
            }
            if fileBytes > 0, fileBytes + data.count > maximumFileBytes {
                try rotate()
            }
            try handle?.write(contentsOf: data)
            fileBytes += data.count
        } catch {
            // ログは best-effort。次の行で開き直す。
            try? handle?.close()
            handle = nil
        }
    }

    private func open() throws {
        let url = fileURL(0)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        fileBytes = try Int(handle.seekToEnd())
        self.handle = handle
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: fileURL(maximumFileCount - 1))
        for index in stride(from: maximumFileCount - 2, through: 0, by: -1) {
            try? FileManager.default.moveItem(at: fileURL(index), to: fileURL(index + 1))
        }
        try open()
    }

    private func fileURL(_ index: Int) -> URL {
        directoryURL.appending(path: index == 0 ? "Dahlia.log" : "Dahlia.\(index).log", directoryHint: .notDirectory)
    }
}
