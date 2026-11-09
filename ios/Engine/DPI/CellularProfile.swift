#if CELLULAR
import Foundation

/// A configuration profile with the operator's APN and our proxy, so apps
/// use the bypass on mobile data too. iOS has no PAC for cellular, so the
/// proxy is fixed: while the app isn't running, web traffic on mobile data
/// fails until the profile is removed or the app is opened again.
enum CellularProfile {
    struct Operator: Identifiable, Hashable {
        let name: String
        let apn: String
        let user: String
        let password: String
        var id: String { name }
    }

    static let operators: [Operator] = [
        Operator(name: "МТС", apn: "internet.mts.ru", user: "mts", password: "mts"),
        Operator(name: "МегаФон", apn: "internet", user: "gdata", password: "gdata"),
        Operator(name: "Билайн", apn: "internet.beeline.ru", user: "beeline", password: "beeline"),
        Operator(name: "Т2 (Tele2)", apn: "internet.tele2.ru", user: "", password: ""),
        Operator(name: "Yota", apn: "internet.yota", user: "", password: ""),
        Operator(name: "Тинькофф Мобайл (Т-Мобайл)", apn: "m.tinkoff", user: "", password: ""),
        Operator(name: "СберМобайл", apn: "internet.sberbank-tele.com", user: "", password: ""),
    ]

    static func make(_ s: DPISettings) -> Data {
        var apn: [String: Any] = [
            "Name": s.apn,
            "AuthenticationType": "PAP",
            "ProxyServer": "127.0.0.1",
            "ProxyServerPort": s.port,
        ]
        var attach: [String: Any] = ["Name": s.apn, "AuthenticationType": "PAP"]
        if !s.apnUser.isEmpty {
            apn["Username"] = s.apnUser
            attach["Username"] = s.apnUser
        }
        if !s.apnPassword.isEmpty {
            apn["Password"] = s.apnPassword
            attach["Password"] = s.apnPassword
        }
        let cellular: [String: Any] = [
            "PayloadType": "com.apple.cellular",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.pustoyinside.tgwsproxy.cellular.apn",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Сотовая сеть через TG Proxy",
            "AttachAPN": attach,
            "APNs": [apn],
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.pustoyinside.tgwsproxy.cellular",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "TG Proxy — мобильный интернет",
            "PayloadDescription": "Направляет веб-трафик мобильного интернета через обход в приложении TG Proxy (127.0.0.1:\(s.port)). Удали профиль, если приложение больше не используешь.",
            "PayloadOrganization": "TG Proxy",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [cellular],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
    }
}
#endif
