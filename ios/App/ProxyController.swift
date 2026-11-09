import Foundation
import UIKit

/// Runs the proxy inside the app and keeps the app alive in the background.
@MainActor
final class ProxyController: ObservableObject {
    @Published private(set) var running = false
    @Published var proxy = ProxyStatus()
    @Published var lastError: String?
    @Published var keepAliveProblem: String?
    @Published var settings: ProxySettings {
        didSet { UserDefaults.standard.set(settings.encoded(), forKey: "settings") }
    }
    @Published var keepAliveMode: KeepAliveMode {
        didSet {
            UserDefaults.standard.set(keepAliveMode.rawValue, forKey: "keepAlive")
            if running { keepAlive.start(keepAliveMode) }
        }
    }
    @Published var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") }
    }

    private var server: ProxyServer?
    private let keepAlive = KeepAlive()
    private var poll: Timer?

    init() {
        let d = UserDefaults.standard
        settings = ProxySettings.decode(d.data(forKey: "settings")) ?? ProxySettings()
        keepAliveMode = KeepAliveMode(rawValue: d.string(forKey: "keepAlive") ?? "") ?? .location
        autoStart = d.object(forKey: "autoStart") as? Bool ?? true
        d.set(settings.encoded(), forKey: "settings")
        keepAlive.onAuthorizationProblem = { [weak self] msg in
            Task { @MainActor in self?.keepAliveProblem = msg }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.proxy = stats.snapshot() }
        }
        if autoStart && d.bool(forKey: "wasRunning") { start() }
    }

    var statusText: String {
        if !running { return "Выключен" }
        if proxy.listening { return "Работает на 127.0.0.1:\(settings.port)" }
        if let e = proxy.listenError { return "Ошибка порта: \(e)" }
        return "Запускается…"
    }

    func start() {
        lastError = nil
        guard settings.isSecretValid else {
            lastError = "Секрет должен состоять из 32 шестнадцатеричных символов"
            return
        }
        let s = ProxyServer(settings: settings)
        do {
            try s.start()
        } catch {
            lastError = "Не удалось запустить прокси: \(error.localizedDescription)"
            return
        }
        server = s
        keepAlive.start(keepAliveMode)
        running = true
        UserDefaults.standard.set(true, forKey: "wasRunning")
    }

    func stop() {
        server?.stop()
        server = nil
        keepAlive.stop()
        running = false
        keepAliveProblem = nil
        UserDefaults.standard.set(false, forKey: "wasRunning")
        plog.info("Proxy stopped")
    }

    /// Applies changed settings: restarts if running.
    func apply() {
        guard running else { return }
        stop()
        // Let the listener release the port.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
    }

    func logText() -> String {
        let t = plog.text()
        return t.isEmpty ? "Журнал пуст. Он появится после включения прокси." : t
    }
}
