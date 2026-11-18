import Foundation
import os

/// Per-layer loggers. Every message also goes to the app's log file
/// (FileMirror: Library/Caches/Logs/screener.log — not Documents, so it is
/// not visible in Files, not backed up, and protected while the iPad is
/// locked). "Share Log" shares a redacted copy (LogExport).
///
/// Privacy (security review M2): interpolate host names / addresses /
/// usernames / Mac names as `\(private: value)`. In os_log those values are
/// `privacy: .private`; in the log file they are wrapped in ⟦…⟧ in DEBUG
/// builds (so the redacted export can hash them) and written as `<private>`
/// in Release builds.
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

        /// A message with `\(private: …)` values.
        func info(_ msg: LogMessage) {
            if msg.privateValues.isEmpty {
                logger.info("\(msg.redacted, privacy: .public)")
            } else {
                logger.info("\(msg.redacted, privacy: .public) [\(msg.privateValues.joined(separator: ", "), privacy: .private)]")
            }
            FileMirror.shared.write("[\(name)] \(msg.fileText)")
        }

        func error(_ msg: LogMessage) {
            if msg.privateValues.isEmpty {
                logger.error("\(msg.redacted, privacy: .public)")
            } else {
                logger.error("\(msg.redacted, privacy: .public) [\(msg.privateValues.joined(separator: ", "), privacy: .private)]")
            }
            FileMirror.shared.write("[\(name)] ERROR \(msg.fileText)")
        }
    }
}

/// A log line whose `\(private: x)` parts are kept out of public logs.
struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    /// Private values replaced by `<private>`.
    let redacted: String
    /// Private values wrapped in ⟦…⟧ (LogExport hashes them).
    let marked: String
    let privateValues: [String]

    static let open = "⟦", close = "⟧"

    struct StringInterpolation: StringInterpolationProtocol {
        var redacted = "", marked = ""
        var privateValues: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ s: String) { redacted += s; marked += s }
        mutating func appendInterpolation<T>(_ value: T) {
            let d = String(describing: value)
            redacted += d; marked += d
        }
        mutating func appendInterpolation<T>(private value: T) {
            // Markers inside a value would confuse the export: strip them.
            let d = String(describing: value).replacingOccurrences(of: LogMessage.open, with: "")
                .replacingOccurrences(of: LogMessage.close, with: "")
            redacted += "<private>"
            marked += LogMessage.open + d + LogMessage.close
            privateValues.append(d)
        }
    }

    init(stringLiteral value: String) { redacted = value; marked = value; privateValues = [] }
    init(stringInterpolation i: StringInterpolation) {
        redacted = i.redacted; marked = i.marked; privateValues = i.privateValues
    }

    /// What the log file gets: never the private values in Release.
    var fileText: String {
        #if DEBUG
        marked
        #else
        redacted
        #endif
    }
}

final class FileMirror: @unchecked Sendable {
    // All mutable state (handle, formatter) is confined to queue
    static let shared = FileMirror()
    private let queue = DispatchQueue(label: "screener.filelog")
    private var handle: FileHandle?
    private let formatter = ISO8601DateFormatter()

    /// Library/Caches/Logs: app-private (not shared with Files, unlike
    /// Documents), never backed up.
    static var directory: URL { URL.cachesDirectory.appendingPathComponent("Logs", isDirectory: true) }
    static var url: URL { directory.appendingPathComponent("screener.log") }

    private init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var dir = Self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        // Truncate per launch; unreadable while the iPad is locked.
        fm.createFile(atPath: Self.url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        handle = try? FileHandle(forWritingTo: Self.url)
        if handle == nil {
            os.Logger(subsystem: "com.screener", category: "app").error("Log file could not be opened")
        }
        formatter.formatOptions = [.withTime, .withFractionalSeconds]
        // The log used to live in Documents (shared with Files): remove it.
        let legacy = URL.documentsDirectory.appendingPathComponent("screener.log")
        try? fm.removeItem(at: legacy)
    }

    func write(_ line: String) {
        let now = Date()
        queue.async {
            let stamp = self.formatter.string(from: now)
            // The throwing write: with complete protection the file is
            // unwritable while locked, and the non-throwing one would raise.
            try? self.handle?.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
        }
    }

    /// Waits for queued lines to reach the file.
    func flush() { queue.sync {} }
}

/// "Share Log": a redacted copy of the log, written to a temporary file.
enum LogExport {
    /// The redacted copy (in the temporary directory, complete protection).
    static func makeRedactedCopy() throws -> URL {
        FileMirror.shared.flush()
        let text = (try? String(contentsOf: FileMirror.url, encoding: .utf8)) ?? ""
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("screener-redacted.log")
        try Data(redact(text).utf8).write(to: out, options: [.atomic, .completeFileProtection])
        return out
    }

    /// ⟦private⟧ values → a short stable hash; IPv4 → x.x.x.N; IPv6 →
    /// <ipv6>; *.local host names → a hash.
    static func redact(_ text: String) -> String {
        var s = text
        // ⟦…⟧ private values.
        if let re = try? NSRegularExpression(pattern: "⟦([^⟧]*)⟧") {
            s = replace(re, in: s) { "#" + shortHash($0[1]) }
        }
        // IPv4 (keep the last octet: enough to tell hosts apart in a log).
        if let re = try? NSRegularExpression(pattern: #"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])"#) {
            s = replace(re, in: s) { "x.x.x.\($0[4])" }
        }
        // IPv6 (two or more colon groups with hex; skips times like 12:34:56).
        if let re = try? NSRegularExpression(pattern: #"(?<![\w:])(?=[0-9A-Fa-f:]*[A-Fa-f])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![\w:])"#) {
            s = replace(re, in: s) { _ in "<ipv6>" }
        }
        // Bonjour / mDNS host names.
        if let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9][A-Za-z0-9-]*\.local\b\.?"#) {
            s = replace(re, in: s) { "#" + shortHash($0[0]) }
        }
        return s
    }

    static func shortHash(_ s: String) -> String {
        Hash.sha256(Data(s.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func replace(_ re: NSRegularExpression, in s: String, _ f: ([String]) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

extension Duration {
    /// Whole milliseconds, for timing logs.
    var ms: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}
