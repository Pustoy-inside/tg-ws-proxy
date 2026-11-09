import Foundation
import Network
import Security

enum StreamError: Error, CustomStringConvertible {
    case timeout
    case closed
    case failed(String)

    var description: String {
        switch self {
        case .timeout: return "timeout"
        case .closed: return "closed"
        case .failed(let s): return s
        }
    }
}

/// Resumes a continuation at most once (connection state callbacks and
/// timeouts race each other).
final class Once<T> {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { cont = c }
    func resume(_ r: Result<T, Error>) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(with: r)
    }
}

/// async/await wrapper around NWConnection with a read buffer.
/// One reader and one writer at a time.
final class NetStream {
    let conn: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private let stateLock = NSLock()
    private var _closed = false

    var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _closed
    }

    private func markClosed() {
        stateLock.lock(); _closed = true; stateLock.unlock()
    }

    /// Wraps an accepted connection and starts it.
    init(accepted: NWConnection) {
        conn = accepted
        queue = DispatchQueue(label: "stream")
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.markClosed()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private init(conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    enum Transport {
        case plain
        case tls(sni: String, verifyHostname: Bool)
    }

    static func connect(host: String, port: UInt16, security: Transport,
                        timeout: TimeInterval = 10) async throws -> NetStream {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(max(1, timeout))
        let params: NWParameters
        switch security {
        case .plain:
            params = NWParameters(tls: nil, tcp: tcp)
        case .tls(let sni, let verifyHostname):
            let tls = NWProtocolTLS.Options()
            let sec = tls.securityProtocolOptions
            sec_protocol_options_set_tls_server_name(sec, sni)
            sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
            if !verifyHostname {
                // Like Python's check_hostname=False: chain must be valid,
                // the name is not checked (domain fronting).
                sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
                    let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                    SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil))
                    complete(SecTrustEvaluateWithError(trust, nil))
                }, DispatchQueue.global())
            }
            params = NWParameters(tls: tls, tcp: tcp)
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: port)!)
        let conn = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "stream.out")
        let stream = NetStream(conn: conn, queue: queue)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once(c)
            conn.stateUpdateHandler = { [weak stream] st in
                switch st {
                case .ready:
                    once.resume(.success(()))
                case .waiting(let e):
                    // No route / refused: don't wait for the network to change.
                    once.resume(.failure(StreamError.failed("waiting: \(e)")))
                    conn.cancel()
                case .failed(let e):
                    stream?.markClosed()
                    once.resume(.failure(StreamError.failed("\(e)")))
                case .cancelled:
                    stream?.markClosed()
                    once.resume(.failure(StreamError.closed))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(StreamError.timeout))
                if conn.state != .ready { conn.cancel() }
            }
        }
        return stream
    }

    private func receiveRaw(max: Int) async throws -> Data? {
        if isClosed && buffer.isEmpty { return nil }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, complete, error in
                if let data, !data.isEmpty {
                    c.resume(returning: data)
                } else if let error {
                    c.resume(throwing: StreamError.failed("\(error)"))
                } else if complete {
                    c.resume(returning: nil)
                } else {
                    c.resume(returning: Data())
                }
            }
        }
    }

    /// Up to `max` bytes; nil at end of stream.
    func read(max: Int = 65536) async throws -> Data? {
        if !buffer.isEmpty {
            let n = min(max, buffer.count)
            let out = buffer.prefix(n)
            buffer.removeFirst(n)
            return Data(out)
        }
        while true {
            guard let d = try await receiveRaw(max: max) else { return nil }
            if !d.isEmpty { return d }
        }
    }

    func readExactly(_ n: Int) async throws -> Data {
        while buffer.count < n {
            guard let d = try await receiveRaw(max: max(65536, n - buffer.count)) else {
                throw StreamError.closed
            }
            buffer.append(d)
        }
        let out = Data(buffer.prefix(n))
        buffer.removeFirst(n)
        return out
    }

    func readLine(limit: Int = 16384) async throws -> Data {
        while true {
            if let i = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[buffer.startIndex...i])
                buffer.removeSubrange(buffer.startIndex...i)
                return line
            }
            if buffer.count > limit { throw StreamError.failed("line too long") }
            guard let d = try await receiveRaw(max: 65536) else {
                let rest = buffer
                buffer.removeAll()
                return rest
            }
            buffer.append(d)
        }
    }

    func write(_ data: Data) async throws {
        if data.isEmpty { return }
        if isClosed { throw StreamError.closed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: StreamError.failed("\(error)")) }
                else { c.resume() }
            })
        }
    }

    func close() {
        markClosed()
        conn.cancel()
    }
}

/// Runs `op`; if it takes longer than `seconds`, closes `streams` so a
/// pending read or write fails, and reports a timeout.
func withDeadline<T>(_ seconds: TimeInterval, closing streams: [NetStream],
                     _ op: () async throws -> T) async throws -> T {
    let fired = Flag()
    let item = DispatchWorkItem {
        fired.set()
        streams.forEach { $0.close() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    defer { item.cancel() }
    do {
        return try await op()
    } catch {
        if fired.value { throw StreamError.timeout }
        throw error
    }
}

final class Flag {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
