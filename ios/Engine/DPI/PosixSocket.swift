import Foundation
import Darwin

/// Non-blocking BSD socket with async read/write. Needed instead of
/// Network.framework for the bypass: it lets us change the TTL between
/// writes and send urgent (OOB) bytes.
final class PosixSocket {
    let fd: Int32
    let family: Int32
    private let queue = DispatchQueue(label: "psock")
    private let lock = NSLock()
    private var closed = false
    private var sources: [DispatchSourceProtocol] = []

    private init(fd: Int32, family: Int32) {
        self.fd = fd
        self.family = family
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    static func connect(host: String, port: Int, timeout: TimeInterval = 10) async throws -> PosixSocket {
        let addrs = try await resolve(host: host, port: port)
        var lastError: Error = StreamError.failed("no address for \(host)")
        for ai in addrs {
            do {
                return try await connectOne(ai, timeout: timeout)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private struct Addr {
        let family: Int32
        let data: Data
    }

    private static func resolve(host: String, port: Int) async throws -> [Addr] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Addr], Error>) in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP
                hints.ai_family = AF_UNSPEC
                var res: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(host, String(port), &hints, &res)
                guard rc == 0, let first = res else {
                    c.resume(throwing: StreamError.failed("DNS \(host): \(String(cString: gai_strerror(rc)))"))
                    return
                }
                var out: [Addr] = []
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let ai = p {
                    if let sa = ai.pointee.ai_addr {
                        out.append(Addr(family: ai.pointee.ai_family,
                                        data: Data(bytes: sa, count: Int(ai.pointee.ai_addrlen))))
                    }
                    p = ai.pointee.ai_next
                }
                freeaddrinfo(first)
                // IPv4 first: TTL tricks are better tested there.
                out = out.filter { $0.family == AF_INET } + out.filter { $0.family != AF_INET }
                c.resume(returning: out)
            }
        }
    }

    private static func connectOne(_ a: Addr, timeout: TimeInterval) async throws -> PosixSocket {
        let fd = socket(a.family, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { throw StreamError.failed("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let s = PosixSocket(fd: fd, family: a.family)
        let rc = a.data.withUnsafeBytes { raw -> Int32 in
            Darwin.connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(a.data.count))
        }
        if rc != 0 && errno != EINPROGRESS {
            let e = String(cString: strerror(errno))
            s.close()
            throw StreamError.failed("connect: \(e)")
        }
        if rc != 0 {
            let ok = await s.waitWritable(timeout: timeout)
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if !ok || err != 0 {
                s.close()
                throw ok ? StreamError.failed("connect: \(String(cString: strerror(err)))") : StreamError.timeout
            }
        }
        return s
    }

    // MARK: Waiting

    private final class Waiter {
        var done = false
    }

    private func wait(read: Bool, timeout: TimeInterval?) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                if isClosed { c.resume(returning: false); return }
                let w = Waiter()
                let src: DispatchSourceProtocol = read
                    ? DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                    : DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                let finish: (Bool) -> Void = { [weak self] ok in
                    guard !w.done else { return }
                    w.done = true
                    src.cancel()
                    if let self {
                        self.lock.lock()
                        self.sources.removeAll { $0 === src }
                        self.lock.unlock()
                    }
                    c.resume(returning: ok)
                }
                src.setEventHandler { finish(true) }
                src.setCancelHandler { finish(false) }
                lock.lock(); sources.append(src); lock.unlock()
                src.resume()
                if let timeout {
                    queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
                }
            }
        }
    }

    private func waitWritable(timeout: TimeInterval) async -> Bool {
        await wait(read: false, timeout: timeout)
    }

    // MARK: IO

    /// Up to `max` bytes; nil at end of stream.
    func read(max: Int = 65536) async throws -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        while true {
            if isClosed { return nil }
            let n = recv(fd, &buf, max, 0)
            if n > 0 { return Data(buf[0..<n]) }
            if n == 0 { return nil }
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                if !(await wait(read: true, timeout: nil)) { return nil }
                continue
            }
            if e == EINTR { continue }
            throw StreamError.failed("recv: \(String(cString: strerror(e)))")
        }
    }

    func write(_ data: Data, flags: Int32 = 0) async throws {
        var off = 0
        let bytes = [UInt8](data)
        while off < bytes.count {
            if isClosed { throw StreamError.closed }
            let n = bytes.withUnsafeBytes { raw in
                send(fd, raw.baseAddress! + off, bytes.count - off, flags)
            }
            if n > 0 { off += n; continue }
            let e = errno
            if n < 0 && (e == EAGAIN || e == EWOULDBLOCK) {
                if !(await wait(read: false, timeout: 30)) { throw StreamError.timeout }
                continue
            }
            if n < 0 && e == EINTR { continue }
            throw StreamError.failed("send: \(String(cString: strerror(e)))")
        }
    }

    func sendOOB(_ byte: UInt8) -> Bool {
        var b = byte
        return send(fd, &b, 1, MSG_OOB) == 1
    }

    @discardableResult
    func setTTL(_ ttl: Int32) -> Bool {
        var v = ttl
        let size = socklen_t(MemoryLayout<Int32>.size)
        if family == AF_INET6 {
            return setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &v, size) == 0
        }
        return setsockopt(fd, IPPROTO_IP, IP_TTL, &v, size) == 0
    }

    func defaultTTL() -> Int32 {
        var v: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if family == AF_INET6 {
            getsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &v, &len)
        } else {
            getsockopt(fd, IPPROTO_IP, IP_TTL, &v, &len)
        }
        return v > 0 ? v : 64
    }

    /// Bytes still waiting to be acknowledged; used to know when a part sent
    /// with a short TTL has left the socket.
    func unsentBytes() -> Int {
        var v: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(fd, SOL_SOCKET, SO_NWRITE, &v, &len) != 0 { return 0 }
        return Int(v)
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let srcs = sources
        sources = []
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        queue.async { [fd] in
            srcs.forEach { $0.cancel() }
            // Let cancel handlers run before the descriptor is reused.
            self.queue.asyncAfter(deadline: .now() + 1) { _ = Darwin.close(fd) }
        }
    }
}
