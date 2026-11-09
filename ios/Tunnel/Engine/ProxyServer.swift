import Foundation
import Network

/// Port of tg_ws_proxy._run/_handle_client and bridge.py: a local MTProto
/// proxy that re-encrypts Telegram's traffic and carries it over WebSocket
/// to the DC (with Cloudflare and plain TCP fallbacks).
final class ProxyServer {
    let settings: ProxySettings
    private let secret: [UInt8]
    private let dcIPs: [Int: String]
    private let pool: WSPool
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "proxy.listener")
    private var stopped = false
    private let tcpBackoff = TCPBackoff()

    init(settings: ProxySettings) {
        self.settings = settings
        var s = [UInt8]()
        var it = settings.secret.makeIterator()
        while let a = it.next(), let b = it.next() {
            s.append(UInt8(String([a, b]), radix: 16) ?? 0)
        }
        secret = s
        dcIPs = settings.parsedDCIPs()
        pool = WSPool(size: max(0, settings.poolSize), dcIPs: dcIPs)
    }

    func start() throws {
        plog.verbose = settings.verboseLog
        CFBalancer.shared.configure(user: settings.cfProxyDomains)
        if settings.cfProxyEnabled { CFBalancer.shared.startRefresh() }
        try startListener()
        plog.info("Telegram MTProto WS Bridge Proxy (iOS)")
        plog.info("Listening on 127.0.0.1:\(settings.port)")
        for dc in dcIPs.keys.sorted() { plog.info("  DC\(dc): \(dcIPs[dc]!)") }
        plog.info("CF proxy: \(settings.cfProxyEnabled ? "enabled" : "disabled")")
        if !settings.cfWorkerDomains.isEmpty {
            plog.info("CF worker: \(settings.cfWorkerDomains.joined(separator: ", "))")
        }
        Task { await pool.warmup() }
    }

    private func startListener() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                 port: NWEndpoint.Port(rawValue: UInt16(settings.port))!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            guard let self, !self.stopped else { conn.cancel(); return }
            let client = NetStream(accepted: conn)
            Task { await self.handle(client) }
        }
        l.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                stats.update { $0.listening = true; $0.listenError = nil }
            case .failed(let e):
                stats.update { $0.listening = false; $0.listenError = "\(e)" }
                plog.warn("Listening socket died (\(e)), restarting")
                l.cancel()
                self.queue.asyncAfter(deadline: .now() + 1) {
                    guard !self.stopped else { return }
                    do { try self.startListener() } catch { plog.error("Failed to restart server: \(error)") }
                }
            case .cancelled:
                stats.update { $0.listening = false }
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        Task { await pool.stop() }
    }

    // MARK: - Client

    private func handle(_ client: NetStream) async {
        stats.update { $0.connectionsTotal += 1; $0.connectionsActive += 1 }
        defer {
            stats.update { $0.connectionsActive -= 1 }
            client.close()
        }
        let label = "c\(Int.random(in: 1000...9999))"
        do {
            let hsData = try await withDeadline(10, closing: [client]) {
                try await client.readExactly(MT.handshakeLen)
            }
            let hs = Array(hsData)
            guard let r = tryHandshake(hs, secret: secret) else {
                stats.update { $0.connectionsBad += 1 }
                plog.warn("[\(label)] bad handshake (wrong secret or proto)")
                _ = try? await withDeadline(10, closing: [client]) {
                    var left = 64 * 1024
                    while left > 0, let d = try await client.read(max: min(4096, left)) { left -= d.count }
                }
                return
            }
            var dc = r.dc
            let isTest = dc >= 10000
            if isTest { dc -= 10000 }
            let dcIdx = r.isMedia ? -dc : dc
            let mediaTag = r.isMedia ? " media" : ""
            plog.debug("[\(label)] handshake ok: DC\(dc)\(mediaTag)")

            let relayInit = generateRelayInit(protoTag: r.protoTag, dcIdx: dcIdx)
            let ctx = CryptoCtx(clientPrekeyIV: r.prekeyAndIV, secret: secret, relayInit: relayInit)

            if let ws = await pool.get(dc: dc, media: r.isMedia, test: isTest) {
                plog.info("[\(label)] DC\(dc)\(mediaTag) -> WS pool hit")
                stats.update { $0.connectionsWS += 1 }
                try await ws.send(relayInit)
                await bridgeWS(client, ws, ctx, label: label, dcTag: "DC\(dc)\(r.isMedia ? "m" : "")",
                               splitter: MsgSplitter(protoTag: r.protoTag))
                return
            }
            plog.info("[\(label)] DC\(dc)\(mediaTag) WS pool unavailable -> fallback")
            let ok = await fallback(client, relayInit, ctx, label: label, dc: dc, test: isTest,
                                    media: r.isMedia, protoTag: r.protoTag)
            if !ok { plog.warn("[\(label)] DC\(dc)\(mediaTag) no fallback available") }
        } catch StreamError.timeout {
            plog.warn("[\(label)] timeout during handshake")
        } catch {
            plog.debug("[\(label)] client closed: \(error)")
        }
    }

    // MARK: - Fallbacks (bridge.do_fallback)

    private func fallback(_ client: NetStream, _ relayInit: [UInt8], _ ctx: CryptoCtx, label: String,
                          dc: Int, test: Bool, media: Bool, protoTag: [UInt8]) async -> Bool {
        let dst = (test ? MT.dcTestIPs : MT.dcDefaultIPs)[dc]
        let useCF = settings.cfProxyEnabled && !test
        let dcTag = "DC\(dc)\(media ? "m" : "")"

        if !settings.cfWorkerDomains.isEmpty, let dst {
            for domain in settings.cfWorkerDomains {
                plog.info("[\(label)] \(dcTag) -> trying CF worker \(domain) for \(dst)")
                do {
                    let ws = try await RawWebSocket.connect(host: domain, domain: domain,
                                                            path: "/apiws?dst=\(dst)&dc=\(dc)", timeout: 10)
                    stats.update { $0.connectionsCF += 1 }
                    try await ws.send(relayInit)
                    await bridgeWS(client, ws, ctx, label: label, dcTag: dcTag, splitter: nil)
                    return true
                } catch {
                    plog.warn("[\(label)] \(dcTag) CF worker \(domain) failed: \(error)")
                }
            }
        }

        if useCF {
            plog.info("[\(label)] \(dcTag) -> trying CF proxy")
            for base in CFBalancer.shared.domains(for: dc) {
                let domain = "kws\(dc).\(base)"
                do {
                    let ws = try await RawWebSocket.connect(host: domain, domain: domain, timeout: 10)
                    if CFBalancer.shared.use(base, for: dc) { plog.info("[\(label)] Switched active CF domain") }
                    stats.update { $0.connectionsCF += 1 }
                    try await ws.send(relayInit)
                    await bridgeWS(client, ws, ctx, label: label, dcTag: dcTag,
                                   splitter: MsgSplitter(protoTag: protoTag))
                    return true
                } catch {
                    plog.warn("[\(label)] \(dcTag) CF proxy failed: \(error)")
                }
            }
        }

        if let dst {
            guard await tcpBackoff.begin(dst) else {
                plog.debug("[\(label)] TCP fallback to \(dst):443 skipped (backoff)")
                return false
            }
            plog.info("[\(label)] TCP fallback to \(dst):443")
            let remote: NetStream
            do {
                remote = try await NetStream.connect(host: dst, port: 443, security: .plain, timeout: 10)
                try await remote.write(Data(relayInit))
                await tcpBackoff.succeeded(dst)
            } catch {
                let delay = await tcpBackoff.failed(dst)
                plog.warn("[\(label)] TCP fallback to \(dst):443 failed: \(error); retry in \(Int(delay))s")
                return false
            }
            stats.update { $0.connectionsTCP += 1 }
            await bridgeTCP(client, remote, ctx, label: label)
            return true
        }
        return false
    }

    // MARK: - Bridges

    private func bridgeWS(_ client: NetStream, _ ws: RawWebSocket, _ ctx: CryptoCtx,
                          label: String, dcTag: String, splitter: MsgSplitter?) async {
        let start = Date()
        let up = Counter(), down = Counter()
        await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    while true {
                        guard let chunk = try await client.read(max: 65536) else {
                            if let tail = splitter?.flush() { try await ws.send(tail) }
                            return "client closed"
                        }
                        up.add(chunk.count)
                        stats.update { $0.bytesUp += Int64(chunk.count) }
                        let plain = ctx.cltDec.update(Array(chunk))
                        let enc = ctx.tgEnc.update(plain)
                        if let splitter {
                            let parts = splitter.split(cipherChunk: enc, plainChunk: plain)
                            if parts.isEmpty { continue }
                            if parts.count > 1 { try await ws.sendBatch(parts) } else { try await ws.send(parts[0]) }
                        } else {
                            try await ws.send(enc)
                        }
                    }
                } catch {
                    return "client: \(error)"
                }
            }
            group.addTask {
                do {
                    while true {
                        guard let data = try await ws.recv() else { return "upstream: ws_close" }
                        down.add(data.count)
                        stats.update { $0.bytesDown += Int64(data.count) }
                        let plain = ctx.tgDec.update(data)
                        try await client.write(ctx.cltEnc.update(plain))
                    }
                } catch {
                    return "upstream: \(error)"
                }
            }
            let reason = await group.next() ?? "?"
            // Closing both ends unblocks the other direction's pending read.
            ws.close()
            client.close()
            group.cancelAll()
            plog.info("[\(label)] \(dcTag) WS session closed (\(reason)): ^\(humanBytes(up.value)) v\(humanBytes(down.value)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        }
    }

    private func bridgeTCP(_ client: NetStream, _ remote: NetStream, _ ctx: CryptoCtx, label: String) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while let d = try? await client.read(max: 65536) {
                    stats.update { $0.bytesUp += Int64(d.count) }
                    let out = ctx.tgEnc.update(ctx.cltDec.update(d))
                    if (try? await remote.write(out)) == nil { break }
                }
            }
            group.addTask {
                while let d = try? await remote.read(max: 65536) {
                    stats.update { $0.bytesDown += Int64(d.count) }
                    let out = ctx.cltEnc.update(ctx.tgDec.update(d))
                    if (try? await client.write(out)) == nil { break }
                }
            }
            _ = await group.next()
            client.close()
            remote.close()
            group.cancelAll()
        }
        plog.debug("[\(label)] TCP session closed")
    }
}

final class Counter {
    private let lock = NSLock()
    private var v: Int64 = 0
    func add(_ n: Int) { lock.lock(); v += Int64(n); lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return v }
}

/// TCP fallback backoff per destination (bridge._tcp_*).
actor TCPBackoff {
    private var failures: [String: Int] = [:]
    private var retryAfter: [String: Date] = [:]
    private var connecting: Set<String> = []

    func begin(_ dst: String) -> Bool {
        if connecting.contains(dst) { return false }
        if let t = retryAfter[dst], Date() < t { return false }
        connecting.insert(dst)
        return true
    }

    func succeeded(_ dst: String) {
        connecting.remove(dst)
        failures[dst] = nil
        retryAfter[dst] = nil
    }

    func failed(_ dst: String) -> TimeInterval {
        connecting.remove(dst)
        let f = (failures[dst] ?? 0) + 1
        failures[dst] = f
        let delay = min(30 * pow(2, Double(min(f - 1, 7))), 3600)
        retryAfter[dst] = Date().addingTimeInterval(delay)
        return delay
    }
}
