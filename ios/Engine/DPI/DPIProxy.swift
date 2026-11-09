import Foundation
import Network

/// Local HTTP proxy (127.0.0.1) for iOS's Wi-Fi proxy setting (via PAC) and,
/// in the cellular build, the APN proxy. For listed domains the first data
/// of each connection is sent with a DPI bypass trick, like zapret/ByeDPI.
final class DPIProxy {
    let settings: DPISettings
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dpi.listener")
    private var stopped = false

    private let strategyLock = NSLock()
    private var _strategy: DesyncStrategy

    /// Can change while running (auto-select on a network change).
    var strategy: DesyncStrategy {
        get { strategyLock.lock(); defer { strategyLock.unlock() }; return _strategy }
        set { strategyLock.lock(); _strategy = newValue; strategyLock.unlock() }
    }

    init(settings: DPISettings, strategy: DesyncStrategy? = nil) {
        self.settings = settings
        _strategy = strategy ?? settings.strategy
    }

    func start() throws {
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
                stats.update { $0.dpiListening = true; $0.dpiListenError = nil }
            case .failed(let e):
                stats.update { $0.dpiListening = false; $0.dpiListenError = "\(e)" }
                plog.warn("DPI: listening socket died (\(e)), restarting")
                l.cancel()
                self.queue.asyncAfter(deadline: .now() + 1) {
                    guard !self.stopped else { return }
                    try? self.start()
                }
            case .cancelled:
                stats.update { $0.dpiListening = false }
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
        plog.info("DPI bypass: HTTP proxy on 127.0.0.1:\(settings.port), strategy \(strategy.rawValue), \(settings.allDomains.count) domains\(settings.applyToAll ? " (all hosts)" : "")")
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
    }

    // MARK: - Requests

    private struct Head {
        let method: String
        let target: String
        let lines: [String]
        let raw: Data
    }

    private func readHead(_ c: NetStream) async throws -> (Head, Data)? {
        var buf = Data()
        let end = Data([0x0d, 0x0a, 0x0d, 0x0a])
        while buf.range(of: end) == nil {
            if buf.count > 32768 { return nil }
            guard let d = try await c.read(max: 16384) else { return nil }
            buf.append(d)
        }
        let r = buf.range(of: end)!
        let headData = buf[buf.startIndex..<r.upperBound]
        let rest = Data(buf[r.upperBound...])
        let text = String(decoding: headData, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return (Head(method: String(parts[0]).uppercased(), target: String(parts[1]),
                     lines: lines, raw: Data(headData)), rest)
    }

    private func handle(_ client: NetStream) async {
        defer { client.close() }
        let label = "d\(Int.random(in: 1000...9999))"
        do {
            guard let r = try await withDeadline(15, closing: [client], { try await self.readHead(client) })
            else { return }
            let (head, rest) = r
            if head.method == "CONNECT" {
                await tunnel(client, head: head, rest: rest, label: label)
            } else if head.target.hasPrefix("/") {
                try await serveLocal(client, head: head)
            } else if head.target.lowercased().hasPrefix("http://") {
                await forwardHTTP(client, head: head, rest: rest, label: label)
            } else {
                try await respond(client, status: "400 Bad Request", type: "text/plain", body: Data("bad request".utf8))
            }
        } catch {
            plog.debug("[\(label)] DPI client: \(error)")
        }
    }

    private func respond(_ c: NetStream, status: String, type: String, body: Data,
                         extra: String = "") async throws {
        var h = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        h += "Cache-Control: no-cache\r\nConnection: close\r\n\(extra)\r\n"
        try await c.write(Data(h.utf8) + body)
    }

    private func serveLocal(_ c: NetStream, head: Head) async throws {
        let path = head.target.split(separator: "?").first.map(String.init) ?? "/"
        switch path {
        case "/proxy.pac", "/wpad.dat":
            try await respond(c, status: "200 OK", type: "application/x-ns-proxy-autoconfig",
                              body: Data(pac().utf8))
        #if CELLULAR
        case "/cellular.mobileconfig":
            try await respond(c, status: "200 OK", type: "application/x-apple-aspen-config",
                              body: CellularProfile.make(settings),
                              extra: "Content-Disposition: attachment; filename=\"tgproxy-cellular.mobileconfig\"\r\n")
        #endif
        default:
            try await respond(c, status: "200 OK", type: "text/plain; charset=utf-8",
                              body: Data("TG Proxy: обход работает.\n".utf8))
        }
    }

    func pac() -> String {
        let list = settings.allDomains.map { "\"\($0)\"" }.joined(separator: ",")
        let proxy = "PROXY 127.0.0.1:\(settings.port); DIRECT"
        if settings.applyToAll {
            return "function FindProxyForURL(url, host) {\n  return \"\(proxy)\";\n}\n"
        }
        return """
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          var d = [\(list)];
          for (var i = 0; i < d.length; i++) {
            if (host == d[i] || dnsDomainIs(host, "." + d[i])) return "\(proxy)";
          }
          return "DIRECT";
        }

        """
    }

    private func splitHostPort(_ s: String, defaultPort: Int) -> (String, Int) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            let port = after.hasPrefix(":") ? Int(after.dropFirst()) ?? defaultPort : defaultPort
            return (host, port)
        }
        if let c = s.lastIndex(of: ":"), let p = Int(s[s.index(after: c)...]) {
            return (String(s[..<c]), p)
        }
        return (s, defaultPort)
    }

    // MARK: - CONNECT (HTTPS)

    private func tunnel(_ client: NetStream, head: Head, rest: Data, label: String) async {
        let (host, port) = splitHostPort(head.target, defaultPort: 443)
        let bypass = settings.matches(host)
        stats.update { $0.dpiConnections += 1; $0.dpiActive += 1 }
        defer { stats.update { $0.dpiActive -= 1 } }
        let server: PosixSocket
        do {
            server = try await PosixSocket.connect(host: host, port: port, timeout: 10)
        } catch {
            stats.update { $0.dpiErrors += 1 }
            plog.warn("[\(label)] \(host):\(port) connect failed: \(error)")
            try? await client.write(Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        defer { server.close() }
        do {
            try await client.write(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            // First data from the app, usually the whole TLS ClientHello.
            var first = [UInt8](rest)
            if first.isEmpty {
                guard let d = try await withDeadline(30, closing: [client], { try await client.read(max: 65536) })
                else { return }
                first = [UInt8](d)
            }
            if let total = TLSHello.recordLength(first) {
                // A large (post-quantum) ClientHello may arrive in parts.
                while first.count < total {
                    guard let d = try await withDeadline(2, closing: [client], { try await client.read(max: 65536) })
                    else { break }
                    first += d
                }
            }
            if bypass {
                let st = strategy
                plog.info("[\(label)] \(host):\(port) -> \(st.rawValue)")
                try await Desync.send(first, to: server, strategy: st, label: label)
            } else {
                plog.debug("[\(label)] \(host):\(port) direct")
                try await server.write(Data(first))
            }
        } catch {
            stats.update { $0.dpiErrors += 1 }
            plog.warn("[\(label)] \(host): \(error)")
            return
        }
        await relay(client, server, label: label, host: host, bypass: bypass)
    }

    // MARK: - Plain HTTP

    private func forwardHTTP(_ client: NetStream, head: Head, rest: Data, label: String) async {
        // http://host[:port]/path -> origin form
        let t = head.target.dropFirst("http://".count)
        let slash = t.firstIndex(of: "/") ?? t.endIndex
        let (host, port) = splitHostPort(String(t[..<slash]), defaultPort: 80)
        let path = slash < t.endIndex ? String(t[slash...]) : "/"
        var lines = head.lines
        let firstParts = lines[0].split(separator: " ")
        let version = firstParts.count >= 3 ? String(firstParts[2]) : "HTTP/1.1"
        lines[0] = "\(head.method) \(path) \(version)"
        lines = lines.filter {
            let l = $0.lowercased()
            return !l.hasPrefix("proxy-connection:") && !l.hasPrefix("connection:")
        }
        lines.append("Connection: close")
        let newHead = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        let bypass = settings.matches(host)
        stats.update { $0.dpiConnections += 1; $0.dpiActive += 1 }
        defer { stats.update { $0.dpiActive -= 1 } }
        do {
            let server = try await PosixSocket.connect(host: host, port: port, timeout: 10)
            defer { server.close() }
            let payload = [UInt8](newHead + rest)
            if bypass {
                try await Desync.send(payload, to: server, strategy: strategy, label: label)
            } else {
                try await server.write(Data(payload))
            }
            await relay(client, server, label: label, host: host, bypass: bypass)
        } catch {
            stats.update { $0.dpiErrors += 1 }
            plog.warn("[\(label)] http \(host): \(error)")
            try? await client.write(Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
        }
    }

    // MARK: - Relay

    private func relay(_ client: NetStream, _ server: PosixSocket, label: String, host: String, bypass: Bool) async {
        let start = Date()
        let down = Counter()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while let d = try? await client.read(max: 65536) {
                    stats.update { $0.dpiBytesUp += Int64(d.count) }
                    if (try? await server.write(d)) == nil { break }
                }
            }
            group.addTask {
                while let d = try? await server.read(max: 65536) {
                    down.add(d.count)
                    stats.update { $0.dpiBytesDown += Int64(d.count) }
                    if (try? await client.write(d)) == nil { break }
                }
            }
            _ = await group.next()
            client.close()
            server.close()
            group.cancelAll()
        }
        let secs = Date().timeIntervalSince(start)
        if bypass && down.value == 0 {
            stats.update { $0.dpiEmpty += 1 }
            plog.warn("[\(label)] \(host): no answer after the bypass (\(String(format: "%.1f", secs))s) — try another strategy")
        } else {
            plog.debug("[\(label)] \(host) closed: v\(humanBytes(down.value)) in \(String(format: "%.1f", secs))s")
        }
    }
}
