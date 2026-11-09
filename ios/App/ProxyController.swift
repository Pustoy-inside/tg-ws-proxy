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
            if running || dpiRunning { keepAlive.start(keepAliveMode) }
        }
    }
    @Published private(set) var dpiRunning = false
    @Published var dpiError: String?
    @Published var dpi: DPISettings {
        didSet { UserDefaults.standard.set((try? JSONEncoder().encode(dpi)) ?? Data(), forKey: "dpi") }
    }
    @Published var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") }
    }

    private var server: ProxyServer?
    private var dpiServer: DPIProxy?
    private let keepAlive = KeepAlive()
    private var poll: Timer?

    init() {
        let d = UserDefaults.standard
        settings = ProxySettings.decode(d.data(forKey: "settings")) ?? ProxySettings()
        keepAliveMode = KeepAliveMode(rawValue: d.string(forKey: "keepAlive") ?? "") ?? .location
        autoStart = d.object(forKey: "autoStart") as? Bool ?? true
        dpi = (d.data(forKey: "dpi")).flatMap { try? JSONDecoder().decode(DPISettings.self, from: $0) } ?? DPISettings()
        d.set(settings.encoded(), forKey: "settings")
        keepAlive.onAuthorizationProblem = { [weak self] msg in
            Task { @MainActor in self?.keepAliveProblem = msg }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.proxy = stats.snapshot() }
        }
        if autoStart && d.bool(forKey: "wasRunning") { start() }
        if autoStart && dpi.enabled { startDPI() }
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
        if !dpiRunning { keepAlive.start(keepAliveMode) }
        running = true
        UserDefaults.standard.set(true, forKey: "wasRunning")
    }

    func stop() {
        server?.stop()
        server = nil
        running = false
        if !dpiRunning { keepAlive.stop(); keepAliveProblem = nil }
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

    // MARK: DPI bypass

    var dpiStatusText: String {
        if !dpiRunning { return "Выключен" }
        if proxy.dpiListening { return "Работает на 127.0.0.1:\(dpi.port)" }
        if let e = proxy.dpiListenError { return "Ошибка порта: \(e)" }
        return "Запускается…"
    }

    func startDPI() {
        dpiError = nil
        if dpi.port == settings.port {
            dpiError = "Порт обхода совпадает с портом прокси Telegram"
            return
        }
        let s = DPIProxy(settings: dpi)
        do {
            try s.start()
        } catch {
            dpiError = "Не удалось запустить обход: \(error.localizedDescription)"
            return
        }
        dpiServer = s
        if !running { keepAlive.start(keepAliveMode) }
        dpiRunning = true
        if !dpi.enabled { dpi.enabled = true }
    }

    func stopDPI() {
        dpiServer?.stop()
        dpiServer = nil
        dpiRunning = false
        if dpi.enabled { dpi.enabled = false }
        if !running { keepAlive.stop(); keepAliveProblem = nil }
        plog.info("DPI bypass stopped")
    }

    func applyDPI() {
        guard dpiRunning else { return }
        dpiServer?.stop()
        dpiServer = nil
        dpiRunning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startDPI() }
    }

    func logText() -> String {
        let t = plog.text()
        return t.isEmpty ? "Журнал пуст. Он появится после включения прокси." : t
    }
}
