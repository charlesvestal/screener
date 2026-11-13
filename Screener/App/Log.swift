import Foundation
import os

/// Per-layer loggers. Every message is also appended to Documents/screener.log
/// so Tools/fetch-ipad-log.sh can read it from the device.
enum Log {
    static let app = Channel("app")
    static let auth = Channel("auth")
    static let record = Channel("record")
    static let control = Channel("control")
    static let media = Channel("media")
    static let video = Channel("video")
    static let audio = Channel("audio")
    static let input = Channel("input")
    static let hosts = Channel("hosts")

    struct Channel: Sendable {
        let logger: Logger
        let name: String
        init(_ name: String) {
            self.name = name
            self.logger = Logger(subsystem: "com.screener", category: name)
        }
        func info(_ msg: String) { logger.info("\(msg, privacy: .public)"); FileMirror.shared.write("[\(name)] \(msg)") }
        func error(_ msg: String) { logger.error("\(msg, privacy: .public)"); FileMirror.shared.write("[\(name)] ERROR \(msg)") }
        func debug(_ msg: String) { logger.debug("\(msg, privacy: .public)") }
    }
}

final class FileMirror: @unchecked Sendable {
    static let shared = FileMirror()
    private let queue = DispatchQueue(label: "screener.filelog")
    private var handle: FileHandle?
    private let formatter = ISO8601DateFormatter()

    private init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("screener.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)   // truncate per launch
        handle = try? FileHandle(forWritingTo: url)
        formatter.formatOptions = [.withTime, .withFractionalSeconds]
    }

    func write(_ line: String) {
        let stamp = formatter.string(from: Date())
        queue.async { [handle] in
            handle?.write(Data("\(stamp) \(line)\n".utf8))
        }
    }
}
