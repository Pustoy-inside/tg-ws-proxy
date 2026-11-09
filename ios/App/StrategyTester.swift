import Foundation

/// Port of zapret-discord-youtube's "Run Tests" (utils/test zapret.ps1):
/// for every strategy, HEAD requests to the targets from utils/targets.txt
/// over TLS 1.2 and TLS 1.3, plus a "TCP 16-20 KB freeze" download check.
/// The strategy with the most passed checks wins (ties: faster).
struct StrategyResult: Codable, Identifiable, Equatable {
    var strategy: DesyncStrategy
    var passed: Int
    var total: Int
    var freezeOK: Bool
    var seconds: Double
    var failedTargets: [String]
    var id: String { strategy.rawValue }

    var score: Int { passed + (freezeOK ? 3 : 0) }
}

struct StrategyTestReport: Codable, Equatable {
    var network: String
    var date: Date
    var results: [StrategyResult]
    var best: DesyncStrategy?
}

final class StrategyTester {
    static let targets: [(String, String)] = [
        ("DiscordMain", "https://discord.com"),
        ("DiscordGateway", "https://gateway.discord.gg"),
        ("DiscordCDN", "https://cdn.discordapp.com"),
        ("DiscordUpdates", "https://updates.discord.com"),
        ("YouTubeWeb", "https://www.youtube.com"),
        ("YouTubeShort", "https://youtu.be"),
        ("YouTubeImage", "https://i.ytimg.com"),
        ("YouTubeVideoRedirect", "https://redirector.googlevideo.com"),
        ("GoogleMain", "https://www.google.com"),
        ("GoogleGstatic", "https://www.gstatic.com"),
        ("CloudflareWeb", "https://www.cloudflare.com"),
        ("CloudflareCDN", "https://cdnjs.cloudflare.com"),
    ]
    /// Big enough pages for the 16-20 KB freeze check.
    static let freezeTargets = ["https://www.youtube.com/", "https://discord.com/"]

    static let testPort = 8899
    static let timeout: TimeInterval = 4

    var onProgress: ((String) -> Void)?

    func run(network: String, strategies: [DesyncStrategy] = DesyncStrategy.allCases) async -> StrategyTestReport {
        var results: [StrategyResult] = []
        for (i, s) in strategies.enumerated() {
            onProgress?("Проверяю \(i + 1) из \(strategies.count): \(s.title)")
            plog.info("Strategy test: \(s.rawValue)")
            if let r = await test(s) {
                results.append(r)
                plog.info("Strategy test: \(s.rawValue) passed \(r.passed)/\(r.total), freeze \(r.freezeOK ? "ok" : "FAIL"), \(String(format: "%.1f", r.seconds))s; failed: \(r.failedTargets.joined(separator: ", "))")
            }
        }
        // Best = highest score among real strategies; "none" only tells
        // whether a bypass is needed at all.
        let candidates = results.filter { $0.strategy != .none && $0.passed > 0 }
        let best = candidates.max { a, b in
            a.score != b.score ? a.score < b.score : a.seconds > b.seconds
        }
        return StrategyTestReport(network: network, date: Date(), results: results, best: best?.strategy)
    }

    private func test(_ strategy: DesyncStrategy) async -> StrategyResult? {
        var cfg = DPISettings()
        cfg.port = Self.testPort
        cfg.strategy = strategy
        cfg.applyToAll = true
        let proxy = DPIProxy(settings: cfg)
        do { try proxy.start() } catch {
            plog.error("Strategy test: can't start test proxy: \(error)")
            return nil
        }
        defer { proxy.stop() }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let start = Date()
        let s12 = session(maxTLS: .TLSv12)
        let s13 = session(maxTLS: .TLSv13)
        defer { s12.invalidateAndCancel(); s13.invalidateAndCancel() }

        var passed = 0
        var failed: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for (name, url) in Self.targets {
                for (label, s) in [("TLS1.2", s12), ("TLS1.3", s13)] {
                    group.addTask { (name + " " + label, await Self.head(url, s)) }
                }
            }
            for await (name, ok) in group {
                if ok { passed += 1 } else { failed.append(name) }
            }
        }
        var freezeOK = true
        for url in Self.freezeTargets {
            let ok = await Self.noFreeze(url, s13)
            if !ok {
                freezeOK = false
                failed.append("16-20KB " + (URL(string: url)?.host ?? url))
            }
        }
        return StrategyResult(strategy: strategy, passed: passed, total: Self.targets.count * 2,
                              freezeOK: freezeOK, seconds: Date().timeIntervalSince(start),
                              failedTargets: failed.sorted())
    }

    private func session(maxTLS: tls_protocol_version_t) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": Self.testPort,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Self.testPort,
        ]
        c.tlsMaximumSupportedProtocolVersion = maxTLS
        c.tlsMinimumSupportedProtocolVersion = maxTLS == .TLSv13 ? .TLSv13 : .TLSv12
        c.timeoutIntervalForRequest = Self.timeout
        c.timeoutIntervalForResource = Self.timeout + 1
        c.httpMaximumConnectionsPerHost = 2
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }

    /// Like curl -I: any HTTP answer means the TLS connection got through.
    private static func head(_ url: String, _ s: URLSession) async -> Bool {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "HEAD"
        do {
            let (_, resp) = try await s.data(for: req)
            return resp is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// The censor's "TCP 16-20" pattern: the connection stalls after about
    /// 16-20 KB. Passes if 64 KB (or the whole page) arrive in time.
    private static func noFreeze(_ url: String, _ s: URLSession) async -> Bool {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        do {
            let (bytes, _) = try await s.bytes(for: req)
            var n = 0
            for try await _ in bytes {
                n += 1
                if n >= 65536 { return true }
            }
            // The whole (smaller) page arrived without a stall.
            return n > 0
        } catch {
            return false
        }
    }
}
