import Foundation
import os

/// In-memory log the app reads through a provider message.
final class ProxyLog {
    static let shared = ProxyLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 2000
    var verbose = false
    private let osLog = Logger(subsystem: "tgwsproxy", category: "proxy")
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func info(_ s: String) { add("INFO ", s) }
    func warn(_ s: String) { add("WARN ", s) }
    func error(_ s: String) { add("ERROR", s) }
    func debug(_ s: @autoclosure () -> String) {
        if verbose { add("DEBUG", s()) }
    }

    private func add(_ level: String, _ s: String) {
        osLog.log("\(level, privacy: .public) \(s, privacy: .public)")
        lock.lock()
        lines.append("\(fmt.string(from: Date()))  \(level)  \(s)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

let plog = ProxyLog.shared

final class ProxyStats {
    static let shared = ProxyStats()
    private let lock = NSLock()
    private var s = ProxyStatus()

    func update(_ f: (inout ProxyStatus) -> Void) {
        lock.lock(); f(&s); lock.unlock()
    }

    func snapshot() -> ProxyStatus {
        lock.lock(); defer { lock.unlock() }
        return s
    }
}

let stats = ProxyStats.shared

func humanBytes(_ n: Int64) -> String {
    var v = Double(n)
    for u in ["B", "KB", "MB", "GB"] {
        if abs(v) < 1024 { return String(format: "%.1f%@", v, u) }
        v /= 1024
    }
    return String(format: "%.1fTB", v)
}
