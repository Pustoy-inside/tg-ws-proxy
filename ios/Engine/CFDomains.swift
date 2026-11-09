import Foundation

/// Cloudflare-proxied domains used as the WebSocket fallback. Same encoded
/// list and refresh URL as the original (proxy/config.py).
final class CFBalancer {
    static let shared = CFBalancer()

    static let refreshURL = URL(string:
        "https://raw.githubusercontent.com/Flowseal/tg-ws-proxy/main/.github/cfproxy-domains.txt")!

    static let encodedDefaults = [
        "virkgj.com", "vmmzovy.com", "mkuosckvso.com", "zaewayzmplad.com", "twdmbzcm.com",
        "awzwsldi.com", "clngqrflngqin.com", "tjacxbqtj.com", "bxaxtxmrw.com", "dmohrsgmohcrwb.com",
        "vwbmtmoi.com", "khgrre.com", "ulihssf.com", "tmhqsdqmfpmk.com", "xwuwoqbm.com",
        "orgcnunpj.com", "zhkuldz.com", "zypoljnslxa.com", "efabnxaowuzs.com", "zaftuzsftqdq.com",
    ]

    /// Port of _dd: Caesar shift by the number of letters, ".com" -> ".co.uk".
    static func decode(_ s: String) -> String {
        guard s.hasSuffix(".com") else { return s }
        let p = String(s.dropLast(4))
        let n = p.filter { $0.isLetter }.count
        var out = ""
        for ch in p.unicodeScalars {
            let v = ch.value
            if (97...122).contains(v) || (65...90).contains(v) {
                let base: UInt32 = v >= 97 ? 97 : 65
                let shifted = (Int(v - base) - n) % 26
                let fixed = shifted < 0 ? shifted + 26 : shifted
                out.unicodeScalars.append(UnicodeScalar(base + UInt32(fixed))!)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        return out + ".co.uk"
    }

    private let lock = NSLock()
    private var domains: [String] = []
    private var perDC: [Int: String] = [:]
    private var userDomains = false

    func configure(user: [String]) {
        let list = user.isEmpty ? Self.encodedDefaults.map(Self.decode) : user
        setDomains(list)
        lock.lock(); userDomains = !user.isEmpty; lock.unlock()
    }

    private func setDomains(_ list: [String]) {
        lock.lock(); defer { lock.unlock() }
        if Set(list) == Set(domains) { return }
        domains = list
        perDC = [:]
        for dc in [1, 2, 3, 4, 5, 203] { perDC[dc] = list.randomElement() }
    }

    func domains(for dc: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        if let cur = perDC[dc] { out.append(cur) }
        out += domains.shuffled().filter { $0 != perDC[dc] }
        return out
    }

    @discardableResult
    func use(_ domain: String, for dc: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if perDC[dc] == domain { return false }
        perDC[dc] = domain
        return true
    }

    /// Refreshes the list hourly, like start_cfproxy_domain_refresh.
    private var refreshing = false

    func startRefresh() {
        lock.lock()
        let skip = userDomains || refreshing
        refreshing = true
        lock.unlock()
        if skip { return }
        Task.detached { [weak self] in
            while let self {
                await self.refreshOnce()
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }

    private func refreshOnce() async {
        var comps = URLComponents(url: Self.refreshURL, resolvingAgainstBaseURL: false)!
        comps.query = String((0..<7).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()! })
        var req = URLRequest(url: comps.url!, timeoutInterval: 10)
        req.setValue("tg-ws-proxy", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let lines = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let decoded = Array(Set(lines.map(Self.decode))).filter { $0.contains(".") }
            if decoded.count >= 3 {
                setDomains(decoded)
                plog.info("CF proxy domains refreshed: \(decoded.count)")
            }
        } catch {
            plog.warn("Failed to fetch CF proxy domain list: \(error)")
        }
    }
}
