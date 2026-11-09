import Foundation
import UIKit
import Network

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

    @Published private(set) var network = "other"
    @Published private(set) var testing = false
    @Published private(set) var testProgress = ""
    @Published private(set) var reports: [String: StrategyTestReport] = [:]
    private let pathMonitor = NWPathMonitor()
    private var lastAutoTest: Date?
    private var emptyWindow: [Date] = []
    private var lastEmpty = 0

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
        if let data = d.data(forKey: "strategyReports"),
           let r = try? JSONDecoder().decode([String: StrategyTestReport].self, from: data) {
            reports = r
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular" : "other"
            Task { @MainActor in self?.networkChanged(kind) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "path"))
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
        let s = DPIProxy(settings: dpi, strategy: dpi.effectiveStrategy(network: network))
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
        autoTestIfNeeded()
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

    // MARK: Auto-select

    var networkTitle: String {
        switch network {
        case "wifi": return "Wi-Fi"
        case "cellular": return "мобильный интернет"
        default: return "другая сеть"
        }
    }

    var currentStrategy: DesyncStrategy { dpi.effectiveStrategy(network: network) }

    private func tick() {
        proxy = stats.snapshot()
        // Several "no answer after the bypass" in two minutes: the strategy
        // probably stopped working here; test again (at most every 10 min).
        if proxy.dpiEmpty > lastEmpty {
            for _ in 0..<(proxy.dpiEmpty - lastEmpty) { emptyWindow.append(Date()) }
            lastEmpty = proxy.dpiEmpty
            emptyWindow.removeAll { Date().timeIntervalSince($0) > 120 }
            if emptyWindow.count >= 3, dpi.autoSelect, dpiRunning, !testing,
               Date().timeIntervalSince(lastAutoTest ?? .distantPast) > 600 {
                plog.info("Auto-select: bypass failures, testing strategies again")
                emptyWindow.removeAll()
                Task { await runTest(auto: true) }
            }
        }
    }

    private func networkChanged(_ kind: String) {
        guard kind != network else { return }
        network = kind
        plog.info("Network: \(kind)")
        if let s = dpiServer {
            s.strategy = currentStrategy
            plog.info("Strategy for \(kind): \(s.strategy.rawValue)")
        }
        autoTestIfNeeded()
    }

    private func autoTestIfNeeded() {
        guard dpi.autoSelect, dpiRunning, !testing, network != "other",
              dpi.bestByNetwork[network] == nil,
              Date().timeIntervalSince(lastAutoTest ?? .distantPast) > 120 else { return }
        Task { await runTest(auto: true) }
    }

    /// Tests every strategy on the current network and keeps the best one.
    func runTest(auto: Bool = false) async {
        guard !testing else { return }
        if dpi.port == StrategyTester.testPort || settings.port == StrategyTester.testPort {
            dpiError = "Порт \(StrategyTester.testPort) нужен для проверки, выбери другой порт"
            return
        }
        testing = true
        lastAutoTest = Date()
        let net = network
        let tester = StrategyTester()
        tester.onProgress = { [weak self] t in Task { @MainActor in self?.testProgress = t } }
        let report = await tester.run(network: net)
        reports[net] = report
        UserDefaults.standard.set((try? JSONEncoder().encode(reports)) ?? Data(), forKey: "strategyReports")
        if let best = report.best {
            dpi.bestByNetwork[net] = best
            if net == network, let s = dpiServer, dpi.autoSelect { s.strategy = best }
            testProgress = "Лучший способ: \(best.title)"
            plog.info("Auto-select: best for \(net) is \(best.rawValue)")
        } else {
            testProgress = "Ни один способ не прошёл проверку"
            plog.warn("Auto-select: no strategy passed on \(net)")
        }
        testing = false
    }

    func logText() -> String {
        let t = plog.text()
        return t.isEmpty ? "Журнал пуст. Он появится после включения прокси." : t
    }
}
