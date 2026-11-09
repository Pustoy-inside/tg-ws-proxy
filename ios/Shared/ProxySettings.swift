import Foundation

/// Proxy settings, stored in UserDefaults.
struct ProxySettings: Codable, Equatable {
    var port: Int = 1443
    /// 32 hex characters.
    var secret: String = ProxySettings.randomSecret()
    /// "DC:IP" lines, as in the original's --dc-ip.
    var dcIPs: [String] = ["2:149.154.167.220", "4:149.154.167.220"]
    var poolSize: Int = 4
    var cfProxyEnabled: Bool = true
    var cfProxyDomains: [String] = []
    var cfWorkerDomains: [String] = []
    var verboseLog: Bool = false

    static func randomSecret() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    var telegramLink: String {
        "tg://proxy?server=127.0.0.1&port=\(port)&secret=dd\(secret)"
    }

    var isSecretValid: Bool {
        secret.count == 32 && secret.allSatisfy { $0.isHexDigit }
    }

    func parsedDCIPs() -> [Int: String] {
        var result: [Int: String] = [:]
        for line in dcIPs {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let dc = Int(parts[0]) else { continue }
            let ip = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let octets = ip.split(separator: ".")
            guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { continue }
            result[dc] = ip
        }
        return result
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data?) -> ProxySettings? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ProxySettings.self, from: data)
    }
}

struct ProxyStatus: Codable {
    var listening: Bool = false
    var listenError: String?
    var connectionsTotal: Int = 0
    var connectionsActive: Int = 0
    var connectionsWS: Int = 0
    var connectionsCF: Int = 0
    var connectionsTCP: Int = 0
    var connectionsBad: Int = 0
    var bytesUp: Int64 = 0
    var bytesDown: Int64 = 0
    var poolHits: Int = 0
    var poolMisses: Int = 0
}
