import Foundation
import NetworkExtension
import Combine

@MainActor
final class TunnelManager: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var proxy = ProxyStatus()
    @Published var lastError: String?
    @Published var settings: ProxySettings {
        didSet { saveLocal() }
    }
    @Published var autoReconnect: Bool {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var poll: Timer?

    init() {
        if let d = UserDefaults.standard.data(forKey: "settings"), let s = ProxySettings.decode(d) {
            settings = s
        } else {
            settings = ProxySettings()
        }
        autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true
        saveLocal()
        Task { await load() }
    }

    private func saveLocal() {
        UserDefaults.standard.set(settings.encoded(), forKey: "settings")
    }

    var isOn: Bool { status == .connected || status == .connecting || status == .reasserting }

    var statusText: String {
        switch status {
        case .connected: return proxy.listening ? "Работает" : "Запускается…"
        case .connecting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .reasserting: return "Переподключение…"
        case .disconnected, .invalid: return "Выключен"
        @unknown default: return "—"
        }
    }

    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = all.first
        } catch {
            lastError = "Не удалось прочитать настройки VPN: \(error.localizedDescription)"
        }
        observe()
    }

    private func observe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        status = manager?.connection.status ?? .invalid
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager?.connection, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.statusChanged() }
        }
        statusChanged()
    }

    private func statusChanged() {
        status = manager?.connection.status ?? .invalid
        poll?.invalidate()
        if status == .connected {
            poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refreshStatus() }
            }
            Task { await refreshStatus() }
        } else {
            proxy = ProxyStatus()
        }
    }

    private func configure() async throws -> NETunnelProviderManager {
        let m = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        // Sideloading tools rewrite bundle IDs; the extension's ID always
        // follows the app's.
        proto.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".tunnel"
        proto.serverAddress = "127.0.0.1:\(settings.port)"
        proto.providerConfiguration = [ProxySettings.providerKey: settings.encoded()]
        proto.disconnectOnSleep = false
        m.protocolConfiguration = proto
        m.localizedDescription = "TG WS Proxy"
        m.isEnabled = true
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        m.onDemandRules = [rule]
        m.isOnDemandEnabled = autoReconnect
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        if manager !== m {
            manager = m
            observe()
        }
        return m
    }

    func start() async {
        lastError = nil
        guard settings.isSecretValid else {
            lastError = "Секрет должен состоять из 32 шестнадцатеричных символов"
            return
        }
        do {
            let m = try await configure()
            try m.connection.startVPNTunnel()
        } catch {
            lastError = "Не удалось включить: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let m = manager else { return }
        if m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            try? await m.saveToPreferences()
        }
        m.connection.stopVPNTunnel()
    }

    /// Applies changed settings: reconnects if the proxy is running.
    func apply() async {
        let wasOn = isOn
        if wasOn {
            await stop()
            for _ in 0..<30 where status != .disconnected && status != .invalid {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await start()
        }
    }

    private func send(_ msg: ProviderMessage) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return nil }
        return await withCheckedContinuation { c in
            do {
                try session.sendProviderMessage(Data(msg.rawValue.utf8)) { c.resume(returning: $0) }
            } catch {
                c.resume(returning: nil)
            }
        }
    }

    func refreshStatus() async {
        if let d = await send(.status), let s = try? JSONDecoder().decode(ProxyStatus.self, from: d) {
            proxy = s
        }
    }

    func fetchLog() async -> String {
        guard let d = await send(.log) else { return "Прокси не запущен — журнал появится после включения." }
        let t = String(decoding: d, as: UTF8.self)
        return t.isEmpty ? "Журнал пуст." : t
    }
}
