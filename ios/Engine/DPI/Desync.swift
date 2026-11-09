import Foundation

enum TLSHello {
    /// Total length of the first TLS record if `d` starts with a handshake
    /// record, else nil.
    static func recordLength(_ d: [UInt8]) -> Int? {
        guard d.count >= 5, d[0] == 0x16, d[1] == 0x03 else { return nil }
        return 5 + (Int(d[3]) << 8 | Int(d[4]))
    }

    /// Offset and length of the SNI host name inside a ClientHello record.
    static func sni(_ d: [UInt8]) -> (offset: Int, length: Int, host: String)? {
        guard let total = recordLength(d), d.count >= 9, d[5] == 0x01 else { return nil }
        let end = min(total, d.count)
        var p = 5 + 4 + 2 + 32 // record hdr, handshake hdr, version, random
        func u8() -> Int? { guard p < end else { return nil }; defer { p += 1 }; return Int(d[p]) }
        func u16() -> Int? { guard p + 1 < end else { return nil }; defer { p += 2 }; return Int(d[p]) << 8 | Int(d[p + 1]) }
        guard let sid = u8() else { return nil }; p += sid
        guard let cs = u16() else { return nil }; p += cs
        guard let cm = u8() else { return nil }; p += cm
        guard let extLen = u16() else { return nil }
        let extEnd = min(end, p + extLen)
        while p + 4 <= extEnd {
            guard let type = u16(), let len = u16() else { return nil }
            if type == 0 {
                var q = p
                guard q + 5 <= extEnd else { return nil }
                q += 2 // list length
                guard d[q] == 0 else { return nil }
                let nameLen = Int(d[q + 1]) << 8 | Int(d[q + 2])
                q += 3
                guard q + nameLen <= extEnd else { return nil }
                let host = String(decoding: d[q..<(q + nameLen)], as: UTF8.self)
                return (q, nameLen, host)
            }
            p += len
        }
        return nil
    }

    /// Splits the first TLS record into two records at `pos` bytes of payload.
    static func splitRecord(_ d: [UInt8], at pos: Int) -> [UInt8]? {
        guard let total = recordLength(d), total <= d.count else { return nil }
        let payloadLen = total - 5
        guard pos > 0, pos < payloadLen else { return nil }
        let hdr = Array(d[0..<3])
        var out = hdr + [UInt8(pos >> 8), UInt8(pos & 0xff)] + Array(d[5..<(5 + pos)])
        let rest = payloadLen - pos
        out += hdr + [UInt8(rest >> 8), UInt8(rest & 0xff)] + Array(d[(5 + pos)..<total])
        out += Array(d[total...])
        return out
    }
}

enum HTTPRequest {
    /// Position of the Host header value in a plain HTTP request.
    static func hostPos(_ d: [UInt8]) -> Int? {
        let needle = Array("\r\nhost:".utf8)
        let n = min(d.count, 4096)
        guard n >= needle.count else { return nil }
        for i in 0...(n - needle.count) {
            var ok = true
            for j in 0..<needle.count {
                var b = d[i + j]
                if b >= 0x41 && b <= 0x5a { b += 0x20 }
                if b != needle[j] { ok = false; break }
            }
            if ok { return i + needle.count }
        }
        return nil
    }
}

/// Sends the first client data to the server with the chosen trick.
enum Desync {
    static func send(_ first: [UInt8], to s: PosixSocket, strategy: DesyncStrategy, label: String) async throws {
        guard strategy != .none, !first.isEmpty else {
            try await s.write(Data(first))
            return
        }
        var data = first
        let tls = TLSHello.recordLength(data) != nil
        let sni = tls ? TLSHello.sni(data) : nil

        // Where the host name starts: SNI for TLS, Host header for HTTP.
        let hostStart: Int? = sni?.offset ?? (tls ? nil : HTTPRequest.hostPos(data))

        switch strategy {
        case .tlsrecSplit, .tlsrecDisorder, .tlsrec:
            if let sni, let r = TLSHello.splitRecord(data, at: sni.offset - 5 + 1) {
                data = r
            }
            switch strategy {
            case .tlsrecSplit: try await writeSplit(data, s, at: [1])
            case .tlsrecDisorder: try await writeDisorder(data, s, at: 1)
            default: try await s.write(Data(data))
            }
        case .split:
            let pos = hostStart.map { $0 + max(1, (sni?.length ?? 4) / 2) } ?? 1
            try await writeSplit(data, s, at: [1, pos])
        case .disorder:
            try await writeDisorder(data, s, at: (hostStart ?? 0) + 1)
        case .oob:
            let pos = (hostStart ?? 0) + 1
            guard pos < data.count else { try await s.write(Data(data)); return }
            try await s.write(Data(data[0..<pos]))
            _ = s.sendOOB(0x61)
            try await Task.sleep(nanoseconds: 3_000_000)
            try await s.write(Data(data[pos...]))
        case .none:
            try await s.write(Data(data))
        }
        plog.debug("[\(label)] desync \(strategy.rawValue) sni=\(sni?.host ?? "-") len=\(first.count)")
    }

    /// Several TCP segments with short pauses so they don't merge.
    private static func writeSplit(_ d: [UInt8], _ s: PosixSocket, at points: [Int]) async throws {
        var prev = 0
        for p in points.sorted() where p > prev && p < d.count {
            try await s.write(Data(d[prev..<p]))
            try await Task.sleep(nanoseconds: 3_000_000)
            prev = p
        }
        try await s.write(Data(d[prev...]))
    }

    /// The first part leaves with TTL 1 and is lost on the first hop, so the
    /// DPI sees the second part first; the kernel resends the first part
    /// later with the normal TTL.
    private static func writeDisorder(_ d: [UInt8], _ s: PosixSocket, at pos: Int) async throws {
        guard pos > 0, pos < d.count else { try await s.write(Data(d)); return }
        let ttl = s.defaultTTL()
        if !s.setTTL(1) { try await writeSplit(d, s, at: [pos]); return }
        try await s.write(Data(d[0..<pos]))
        try await Task.sleep(nanoseconds: 5_000_000)
        s.setTTL(ttl)
        try await s.write(Data(d[pos...]))
    }
}
