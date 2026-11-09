import Foundation

struct WSHandshakeError: Error, CustomStringConvertible {
    let status: Int
    let line: String
    let location: String?
    var isRedirect: Bool { [301, 302, 303, 307, 308].contains(status) }
    var description: String { "HTTP \(status): \(line)" }
}

/// Port of RawWebSocket: client WebSocket over our own TCP/TLS stream, so
/// the TCP target (a DC IP), the TLS SNI and the Host header can differ.
final class RawWebSocket {
    static let maxMessage = 16 * 1024 * 1024

    let stream: NetStream
    private var frag = Data()
    private(set) var closedByPeer = false
    let created = Date()

    var isClosed: Bool { closedByPeer || stream.isClosed }

    private init(stream: NetStream) { self.stream = stream }

    /// host: where TCP goes (IP or name); domain: Host header (and SNI
    /// unless `sni` is given; a given SNI means fronting).
    static func connect(host: String, domain: String, path: String = MT.wsPath,
                        sni: String? = nil, secure: Bool = true,
                        timeout: TimeInterval = 10) async throws -> RawWebSocket {
        let security: NetStream.Transport = secure
            ? .tls(sni: sni ?? domain, verifyHostname: sni == nil)
            : .plain
        let stream = try await NetStream.connect(host: host, port: secure ? 443 : 80,
                                              security: security, timeout: min(timeout, 10))
        do {
            return try await withDeadline(timeout, closing: [stream]) {
                let key = Data(randomBytes(16)).base64EncodedString()
                let req = "GET \(path) HTTP/1.1\r\n"
                    + "Host: \(domain)\r\n"
                    + "Upgrade: websocket\r\n"
                    + "Connection: Upgrade\r\n"
                    + "Sec-WebSocket-Key: \(key)\r\n"
                    + "Sec-WebSocket-Version: 13\r\n"
                    + "Sec-WebSocket-Protocol: binary\r\n"
                    + "\r\n"
                try await stream.write(Data(req.utf8))
                var lines: [String] = []
                while true {
                    let line = try await stream.readLine()
                    if line.isEmpty || line == Data([0x0d, 0x0a]) || line == Data([0x0a]) { break }
                    lines.append(String(decoding: line, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard let first = lines.first else {
                    throw WSHandshakeError(status: 0, line: "empty response", location: nil)
                }
                let parts = first.split(separator: " ", maxSplits: 2)
                let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
                if status == 101 { return RawWebSocket(stream: stream) }
                var location: String?
                for l in lines.dropFirst() {
                    if let c = l.firstIndex(of: ":"),
                       l[..<c].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                        location = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                throw WSHandshakeError(status: status, line: first, location: location)
            }
        } catch {
            stream.close()
            throw error
        }
    }

    func send(_ payload: [UInt8]) async throws {
        if isClosed { throw StreamError.closed }
        try await stream.write(Self.frame(opcode: 0x2, payload))
    }

    func sendBatch(_ parts: [[UInt8]]) async throws {
        if isClosed { throw StreamError.closed }
        var all = Data()
        for p in parts { all.append(Self.frame(opcode: 0x2, p)) }
        try await stream.write(all)
    }

    /// Next binary message; nil when the peer closed.
    func recv() async throws -> Data? {
        while !closedByPeer {
            let (op, payload, fin) = try await readFrame()
            switch op {
            case 0x8:
                closedByPeer = true
                try? await stream.write(Self.frame(opcode: 0x8, Array(payload.prefix(2))))
                return nil
            case 0x9:
                try? await stream.write(Self.frame(opcode: 0xA, Array(payload)))
                continue
            case 0xA:
                continue
            case 0x0, 0x1, 0x2:
                if fin && frag.isEmpty { return payload }
                frag.append(payload)
                if frag.count > Self.maxMessage { throw StreamError.failed("WS message too large") }
                if !fin { continue }
                let m = frag
                frag = Data()
                return m
            default:
                continue
            }
        }
        return nil
    }

    func close() {
        if !isClosed {
            let s = stream
            let f = Self.frame(opcode: 0x8, [])
            Task { try? await s.write(f); s.close() }
        } else {
            stream.close()
        }
    }

    private func readFrame() async throws -> (UInt8, Data, Bool) {
        let hdr = try await stream.readExactly(2)
        let b0 = hdr[hdr.startIndex], b1 = hdr[hdr.startIndex + 1]
        let fin = b0 & 0x80 != 0
        let op = b0 & 0x0f
        var len = Int(b1 & 0x7f)
        if len == 126 {
            let e = try await stream.readExactly(2)
            len = Int(e[e.startIndex]) << 8 | Int(e[e.startIndex + 1])
        } else if len == 127 {
            let e = try await stream.readExactly(8)
            var v: UInt64 = 0
            for b in e { v = v << 8 | UInt64(b) }
            guard v <= UInt64(Self.maxMessage) else { throw StreamError.failed("WS frame too large") }
            len = Int(v)
        }
        if len > Self.maxMessage { throw StreamError.failed("WS frame too large") }
        if b1 & 0x80 != 0 {
            let maskData = try await stream.readExactly(4)
            let mask = Array(maskData)
            let body = try await stream.readExactly(len)
            var p = Array(body)
            for i in 0..<p.count { p[i] ^= mask[i & 3] }
            return (op, Data(p), fin)
        }
        if len == 0 { return (op, Data(), fin) }
        let p = try await stream.readExactly(len)
        return (op, p, fin)
    }

    static func frame(opcode: UInt8, _ payload: [UInt8]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(payload.count + 14)
        out.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n < 65536 {
            out.append(0x80 | 126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xff))
        } else {
            out.append(0x80 | 127)
            for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(s)) & 0xff)) }
        }
        let mask = randomBytes(4)
        out += mask
        let start = out.count
        out += payload
        out.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n { buf[start + i] ^= mask[i & 3] }
        }
        return Data(out)
    }
}
