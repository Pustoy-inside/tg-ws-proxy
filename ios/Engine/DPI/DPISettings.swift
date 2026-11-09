import Foundation

/// Bypass strategies, ports of ByeDPI/zapret ideas that work from an
/// ordinary socket (no packet injection on iOS).
enum DesyncStrategy: String, Codable, CaseIterable, Identifiable {
    case tlsrecSplit   // TLS record split at SNI + TCP split at 1
    case tlsrecDisorder // TLS record split at SNI + first byte with TTL 1
    case split         // TCP split in the middle of the SNI
    case disorder      // first part (up to SNI) sent with TTL 1
    case oob           // TCP split at SNI with an urgent (OOB) byte
    case tlsrec        // TLS record split only
    case none

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tlsrecSplit: return "Фрагментация TLS + разбивка"
        case .tlsrecDisorder: return "Фрагментация TLS + перестановка"
        case .split: return "Разбивка по SNI"
        case .disorder: return "Перестановка (disorder)"
        case .oob: return "OOB-байт"
        case .tlsrec: return "Только фрагментация TLS"
        case .none: return "Без обхода (проверка)"
        }
    }
}

struct DPISettings: Codable, Equatable {
    var enabled = false
    var port = 8881
    var strategy: DesyncStrategy = .tlsrecSplit
    var extraDomains: [String] = []
    var applyToAll = false
    // Cellular (APN profile)
    var apn = ""
    var apnUser = ""
    var apnPassword = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DPISettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        strategy = (try? c.decodeIfPresent(DesyncStrategy.self, forKey: .strategy)) ?? d.strategy
        extraDomains = try c.decodeIfPresent([String].self, forKey: .extraDomains) ?? d.extraDomains
        applyToAll = try c.decodeIfPresent(Bool.self, forKey: .applyToAll) ?? d.applyToAll
        apn = try c.decodeIfPresent(String.self, forKey: .apn) ?? d.apn
        apnUser = try c.decodeIfPresent(String.self, forKey: .apnUser) ?? d.apnUser
        apnPassword = try c.decodeIfPresent(String.self, forKey: .apnPassword) ?? d.apnPassword
    }

    var pacURL: String { "http://127.0.0.1:\(port)/proxy.pac" }

    var allDomains: [String] {
        var seen = Set<String>()
        return (DPIDomains.defaults + extraDomains.map { $0.lowercased() })
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// True when `host` is a listed domain or its subdomain.
    func matches(_ host: String) -> Bool {
        if applyToAll { return true }
        let h = host.lowercased()
        return allDomains.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}

/// Domains from zapret-discord-youtube's list-general.txt and list-google.txt.
enum DPIDomains {
    static let defaults: [String] = [
        "7tv.app",
        "7tv.io",
        "betterttv.net",
        "cloudflare-ech.com",
        "cloudflareaccess.com",
        "cloudflareapps.com",
        "cloudflarebolt.com",
        "cloudflareclient.com",
        "cloudflareinsights.com",
        "cloudflareok.com",
        "cloudflarepartners.com",
        "cloudflareportal.com",
        "cloudflarepreview.com",
        "cloudflareresolve.com",
        "cloudflaressl.com",
        "cloudflarestatus.com",
        "cloudflarestorage.com",
        "cloudflarestream.com",
        "cloudflaretest.com",
        "cloudfront.net",
        "dis.gd",
        "discord-activities.com",
        "discord-attachments-uploads-prd.storage.googleapis.com",
        "discord.app",
        "discord.co",
        "discord.com",
        "discord.design",
        "discord.dev",
        "discord.gg",
        "discord.gift",
        "discord.gifts",
        "discord.media",
        "discord.new",
        "discord.status",
        "discord.store",
        "discordactivities.com",
        "discordapp.com",
        "discordapp.net",
        "discordcdn.com",
        "discordmerch.com",
        "discordpartygames.com",
        "discordsays.com",
        "discordsez.com",
        "discordstatus.com",
        "encryptedsni.com",
        "ffzap.com",
        "fonts.googleapis.com",
        "frankerfacez.com",
        "google.ru",
        "googlevideo.com",
        "jnn-pa.googleapis.com",
        "klipy.com",
        "live-video.net",
        "localizeapi.com",
        "play.google.com",
        "stable.dl2.discordapp.net",
        "wide-youtube.l.google.com",
        "www.gstatic.com",
        "youtu.be",
        "youtube-nocookie.com",
        "youtube-ui.l.google.com",
        "youtube.com",
        "youtube.googleapis.com",
        "youtubeembeddedplayer.googleapis.com",
        "youtubei.googleapis.com",
        "youtubekids.com",
        "yt-video-upload.l.google.com",
        "yt3.ggpht.com",
        "yt3.googleusercontent.com",
        "yt4.ggpht.com",
        "ytimg.com",
        "ytimg.l.google.com",
        "zendesk.com",
    ]
}
