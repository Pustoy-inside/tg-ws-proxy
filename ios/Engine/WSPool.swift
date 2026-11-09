import Foundation

struct PoolKey: Hashable {
    let dc: Int
    let media: Bool
    let test: Bool
}

/// Port of _WsPool: keeps a few ready WebSockets per DC so a new Telegram
/// connection doesn't wait for TCP+TLS+upgrade.
actor WSPool {
    static let maxAge: TimeInterval = 120
    static let backoffInitial: TimeInterval = 1
    static let backoffMax: TimeInterval = 3600
    static let frontingSNI = "sprinthost.ru"

    private var idle: [PoolKey: [RawWebSocket]] = [:]
    private var refilling: Set<PoolKey> = []
    private var failures: [PoolKey: Int] = [:]
    private var retryAfter: [PoolKey: Date] = [:]
    private var tryFrontingFirst = false
    private var stopped = false

    let size: Int
    let dcIPs: [Int: String]

    init(size: Int, dcIPs: [Int: String]) {
        self.size = size
        self.dcIPs = dcIPs
    }

    private func isStale(_ ws: RawWebSocket) -> Bool {
        ws.isClosed || Date().timeIntervalSince(ws.created) >= Self.maxAge
    }

    func get(dc: Int, media: Bool, test: Bool) -> RawWebSocket? {
        guard size > 0, let ip = dcIPs[dc] else { return nil }
        let key = PoolKey(dc: dc, media: media, test: test)
        var bucket = idle[key] ?? []
        defer { scheduleRefill(key, ip: ip) }
        while !bucket.isEmpty {
            let ws = bucket.removeFirst()
            if isStale(ws) { ws.close(); continue }
            idle[key] = bucket
            stats.update { $0.poolHits += 1 }
            return ws
        }
        idle[key] = bucket
        stats.update { $0.poolMisses += 1 }
        return nil
    }

    func warmup() {
        for (dc, ip) in dcIPs {
            for media in [false, true] {
                scheduleRefill(PoolKey(dc: dc, media: media, test: false), ip: ip)
            }
        }
        plog.info("WS pool warmup started for \(dcIPs.count) DC(s)")
        Task { await self.rotateLoop() }
    }

    func stop() {
        stopped = true
        for (_, b) in idle { b.forEach { $0.close() } }
        idle = [:]
    }

    /// Drops stale sockets and tops buckets up, every 5 s.
    private func rotateLoop() async {
        while !stopped {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            for (key, bucket) in idle {
                let fresh = bucket.filter { ws in
                    if isStale(ws) { ws.close(); return false }
                    return true
                }
                idle[key] = fresh
                if fresh.count < size, let ip = dcIPs[key.dc] { scheduleRefill(key, ip: ip) }
            }
        }
    }

    private func scheduleRefill(_ key: PoolKey, ip: String) {
        guard size > 0, !stopped, !refilling.contains(key) else { return }
        if let after = retryAfter[key], Date() < after { return }
        refilling.insert(key)
        Task { await self.refill(key, ip: ip) }
    }

    private func refill(_ key: PoolKey, ip: String) async {
        defer { refilling.remove(key) }
        let needed = size - (idle[key]?.count ?? 0)
        if needed <= 0 { return }
        let domains = MT.wsDomains(dc: key.dc, media: key.media)
        let path = key.test ? MT.wsPathTest : MT.wsPath
        let fronting = tryFrontingFirst
        var connected = 0
        await withTaskGroup(of: (RawWebSocket, Bool)?.self) { group in
            for _ in 0..<needed {
                group.addTask { await Self.connectOne(ip: ip, domains: domains, path: path, frontingFirst: fronting) }
            }
            for await r in group {
                guard let (ws, fronted) = r else { continue }
                if stopped { ws.close(); continue }
                idle[key, default: []].append(ws)
                tryFrontingFirst = fronted
                connected += 1
            }
        }
        if connected > 0 {
            failures[key] = nil
            retryAfter[key] = nil
        } else {
            let f = (failures[key] ?? 0) + 1
            failures[key] = f
            let delay = min(Self.backoffInitial * pow(2, Double(min(f - 1, 12))), Self.backoffMax)
            retryAfter[key] = Date().addingTimeInterval(delay)
            plog.info("WS pool refill failed for DC\(key.dc)\(key.media ? "m" : ""), retry in \(Int(delay))s")
        }
    }

    private static func connectOne(ip: String, domains: [String], path: String,
                                   frontingFirst: Bool) async -> (RawWebSocket, Bool)? {
        for domain in domains {
            for fronted in (frontingFirst ? [true, false] : [false, true]) {
                do {
                    let ws = try await RawWebSocket.connect(
                        host: ip, domain: domain, path: path,
                        sni: fronted ? frontingSNI : nil, timeout: fronted ? 7 : 8)
                    plog.debug("WS pool connected \(domain)\(path) via \(ip) (fronting=\(fronted))")
                    return (ws, fronted)
                } catch {
                    plog.debug("WS pool connect \(domain) via \(ip) (fronting=\(fronted)): \(error)")
                }
            }
        }
        return nil
    }
}
