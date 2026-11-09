import SwiftUI
import UIKit

@main
struct TGWSProxyApp: App {
    @StateObject private var tunnel = ProxyController()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(tunnel)
        }
    }
}

enum AppInfo {
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

struct ContentView: View {
    @EnvironmentObject var tunnel: ProxyController
    @State private var copied = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { tunnel.running },
                        set: { on in if on { tunnel.start() } else { tunnel.stop() } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Прокси для Telegram").font(.headline)
                            Text(tunnel.statusText).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    if let e = tunnel.lastError {
                        Text(e).font(.footnote).foregroundColor(.red)
                    }
                    if let e = tunnel.keepAliveProblem {
                        Text(e).font(.footnote).foregroundColor(.orange)
                    }
                    Picker("Работа в фоне", selection: $tunnel.keepAliveMode) {
                        ForEach(KeepAliveMode.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Прокси работает внутри приложения. Чтобы iOS не усыпляла его, пока открыт Telegram, приложение держит включённой геолокацию (грубую, раз в несколько километров) или играет тишину. Не закрывай приложение смахиванием из списка недавних.")
                }

                Section {
                    Button {
                        if let url = URL(string: tunnel.settings.telegramLink) { UIApplication.shared.open(url) }
                    } label: {
                        Label("Добавить прокси в Telegram", systemImage: "paperplane")
                    }
                    Button {
                        UIPasteboard.general.string = tunnel.settings.telegramLink
                        copied = true
                    } label: {
                        Label(copied ? "Ссылка скопирована" : "Скопировать ссылку", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("Telegram")
                } footer: {
                    Text("Один раз добавь прокси в Telegram и включи его там. Вручную: тип MTProto, сервер 127.0.0.1, порт \(tunnel.settings.port), секрет dd\(tunnel.settings.secret).")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { tunnel.dpiRunning },
                        set: { on in if on { tunnel.startDPI() } else { tunnel.stopDPI() } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Обход для YouTube и Discord").font(.headline)
                            Text(tunnel.dpiStatusText).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    if let e = tunnel.dpiError {
                        Text(e).font(.footnote).foregroundColor(.red)
                    }
                    NavigationLink("Настройка обхода") { DPISettingsView() }
                    if tunnel.dpiRunning {
                        row("Соединений через обход", "\(tunnel.proxy.dpiConnections) (сейчас \(tunnel.proxy.dpiActive))")
                        if tunnel.proxy.dpiEmpty > 0 {
                            row("Без ответа после обхода", "\(tunnel.proxy.dpiEmpty)")
                        }
                        if tunnel.proxy.dpiErrors > 0 {
                            row("Ошибки", "\(tunnel.proxy.dpiErrors)")
                        }
                        row("Трафик обхода", "↑\(humanBytesApp(tunnel.proxy.dpiBytesUp)) ↓\(humanBytesApp(tunnel.proxy.dpiBytesDown))")
                    }
                } footer: {
                    Text(dpiFooter)
                }

                if tunnel.running {
                    Section("Сейчас") {
                        row("Активных соединений", "\(tunnel.proxy.connectionsActive)")
                        row("Всего соединений", "\(tunnel.proxy.connectionsTotal)")
                        row("Через WebSocket", "\(tunnel.proxy.connectionsWS)")
                        row("Через Cloudflare", "\(tunnel.proxy.connectionsCF)")
                        row("Напрямую (TCP)", "\(tunnel.proxy.connectionsTCP)")
                        if tunnel.proxy.connectionsBad > 0 {
                            row("Неверный секрет", "\(tunnel.proxy.connectionsBad)")
                        }
                        row("Отправлено", humanBytesApp(tunnel.proxy.bytesUp))
                        row("Получено", humanBytesApp(tunnel.proxy.bytesDown))
                    }
                }

                Section {
                    NavigationLink("Настройки") { SettingsView() }
                    NavigationLink("Журнал") { LogView() }
                } footer: {
                    Text("Сборка \(AppInfo.build) · порт tg-ws-proxy от Flowseal")
                }
            }
            .navigationTitle("TG WS Proxy")
        }
        .navigationViewStyle(.stack)
    }

    private var dpiFooter: String {
        #if CELLULAR
        return "Работает на Wi-Fi через настройку прокси сети и на мобильном интернете через профиль. Голос в Discord не поддерживается. Подробности — в «Настройке обхода»."
        #else
        return "Работает на Wi-Fi: один раз пропиши адрес PAC в настройках сети (см. «Настройка обхода»). Голос в Discord не поддерживается."
        #endif
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary).monospacedDigit() }
    }
}

func humanBytesApp(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
}

struct SettingsView: View {
    @EnvironmentObject var tunnel: ProxyController
    @State private var draft = ProxySettings()
    @State private var dcText = ""
    @State private var cfText = ""
    @State private var workerText = ""
    @State private var portText = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Порт")
                    Spacer()
                    TextField("1443", text: $portText).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
                VStack(alignment: .leading) {
                    Text("Секрет")
                    TextField("32 hex", text: $draft.secret)
                        .font(.system(.footnote, design: .monospaced))
                        .autocapitalization(.none).disableAutocorrection(true)
                }
                Button("Новый секрет") { draft.secret = ProxySettings.randomSecret() }
            } header: { Text("Прокси") } footer: {
                Text("После смены порта или секрета прокси в Telegram нужно добавить заново.")
            }

            Section {
                TextEditor(text: $dcText).font(.system(.footnote, design: .monospaced)).frame(minHeight: 70)
                Stepper("Запас соединений: \(draft.poolSize)", value: $draft.poolSize, in: 0...8)
            } header: { Text("IP дата-центров (DC:IP, по строке)") } footer: {
                Text("Как --dc-ip в оригинале. Для остальных DC работает запасной путь. Если не грузятся фото и видео, оставь только 4:149.154.167.220 или очисти поле.")
            }

            Section {
                Toggle("Запасной путь через Cloudflare", isOn: $draft.cfProxyEnabled)
                VStack(alignment: .leading) {
                    Text("Свои домены CF-прокси").font(.footnote).foregroundColor(.secondary)
                    TextEditor(text: $cfText).font(.system(.footnote, design: .monospaced)).frame(minHeight: 50)
                }
                VStack(alignment: .leading) {
                    Text("Домены Cloudflare Worker").font(.footnote).foregroundColor(.secondary)
                    TextEditor(text: $workerText).font(.system(.footnote, design: .monospaced)).frame(minHeight: 50)
                }
            } header: { Text("Cloudflare") } footer: {
                Text("Пусто — встроенный список доменов, как в оригинале. Настройка своих доменов описана в docs оригинального репозитория.")
            }

            Section {
                Toggle("Включать при запуске приложения", isOn: $tunnel.autoStart)
                Toggle("Подробный журнал", isOn: $draft.verboseLog)
            } footer: {
                Text("Если iOS закроет приложение, прокси включится сам при следующем открытии.")
            }

            Section {
                Button("Сохранить") { save() }
                Button("Сбросить по умолчанию", role: .destructive) {
                    let secret = draft.secret
                    draft = ProxySettings()
                    draft.secret = secret
                    fill()
                }
            }
        }
        .navigationTitle("Настройки")
        .onAppear {
            if !loaded { draft = tunnel.settings; fill(); loaded = true }
        }
    }

    private func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func fill() {
        dcText = draft.dcIPs.joined(separator: "\n")
        cfText = draft.cfProxyDomains.joined(separator: "\n")
        workerText = draft.cfWorkerDomains.joined(separator: "\n")
        portText = String(draft.port)
    }

    private func save() {
        draft.secret = draft.secret.trimmingCharacters(in: .whitespaces).lowercased()
        if draft.secret.hasPrefix("dd") && draft.secret.count == 34 { draft.secret.removeFirst(2) }
        draft.dcIPs = lines(dcText)
        draft.cfProxyDomains = lines(cfText)
        draft.cfWorkerDomains = lines(workerText)
        if let p = Int(portText), (1...65535).contains(p) { draft.port = p }
        tunnel.settings = draft
        tunnel.apply()
    }
}

struct LogView: View {
    @EnvironmentObject var tunnel: ProxyController
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Журнал")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { text = tunnel.logText() } label: { Image(systemName: "arrow.clockwise") }
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear { text = tunnel.logText() }
    }
}

struct DPISettingsView: View {
    @EnvironmentObject var tunnel: ProxyController
    @State private var draft = DPISettings()
    @State private var portText = ""
    @State private var domainsText = ""
    @State private var loaded = false
    @State private var copied = false
    #if CELLULAR
    @State private var operatorName = ""
    #endif

    var body: some View {
        Form {
            Section {
                Picker("Способ", selection: $draft.strategy) {
                    ForEach(DesyncStrategy.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Для всех сайтов, не только из списка", isOn: $draft.applyToAll)
            } header: { Text("Стратегия") } footer: {
                Text("Если YouTube или Discord не грузятся, попробуй другой способ: у разных провайдеров работают разные. В журнале строки «no answer after the bypass» значат, что способ не сработал.")
            }

            Section {
                Text(draft.pacURL).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                Button(copied ? "Адрес скопирован" : "Скопировать адрес PAC") {
                    UIPasteboard.general.string = draft.pacURL
                    copied = true
                }
                Button("Открыть настройки iOS") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
            } header: { Text("Wi-Fi") } footer: {
                Text("Настройки → Wi-Fi → (i) у своей сети → Настройка прокси → Автоматически → вставь адрес. Делается один раз для каждой сети. Если приложение выключено, сайты откроются напрямую, интернет не пропадёт.")
            }

            #if CELLULAR
            Section {
                Picker("Оператор", selection: $operatorName) {
                    Text("Свой APN").tag("")
                    ForEach(CellularProfile.operators) { Text($0.name).tag($0.name) }
                }
                .onChange(of: operatorName) { name in
                    if let o = CellularProfile.operators.first(where: { $0.name == name }) {
                        draft.apn = o.apn; draft.apnUser = o.user; draft.apnPassword = o.password
                    }
                }
                TextField("APN, например internet.mts.ru", text: $draft.apn)
                    .autocapitalization(.none).disableAutocorrection(true)
                TextField("Имя пользователя (если нужно)", text: $draft.apnUser)
                    .autocapitalization(.none).disableAutocorrection(true)
                TextField("Пароль (если нужно)", text: $draft.apnPassword)
                    .autocapitalization(.none).disableAutocorrection(true)
                Button("Установить профиль мобильного интернета") {
                    save()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if let u = URL(string: "http://127.0.0.1:\(draft.port)/cellular.mobileconfig") {
                            UIApplication.shared.open(u)
                        }
                    }
                }
                .disabled(draft.apn.trimmingCharacters(in: .whitespaces).isEmpty || !tunnel.dpiRunning)
            } header: { Text("Мобильный интернет") } footer: {
                Text("Включи обход, выбери оператора и нажми кнопку: Safari скачает профиль. Затем Настройки → Профиль загружен → Установить. Пока приложение не запущено, сайты на мобильном интернете не откроются — удали профиль в Настройки → Основные → VPN и управление устройством, если перестанешь пользоваться. Проверь APN в Настройки → Сотовая связь → Сотовая сеть передачи данных.")
            }
            #endif

            Section {
                HStack {
                    Text("Порт")
                    Spacer()
                    TextField("8881", text: $portText).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing).frame(width: 90)
                }
                VStack(alignment: .leading) {
                    Text("Свои домены (по строке)").font(.footnote).foregroundColor(.secondary)
                    TextEditor(text: $domainsText).font(.system(.footnote, design: .monospaced)).frame(minHeight: 70)
                }
            } header: { Text("Дополнительно") } footer: {
                Text("Встроенный список — \(DPIDomains.defaults.count) доменов YouTube, Discord и Cloudflare из zapret-discord-youtube. После смены порта поменяй адрес PAC в настройках Wi-Fi.")
            }

            Section {
                Button("Сохранить") { save() }
            }
        }
        .navigationTitle("Настройка обхода")
        .onAppear {
            if !loaded {
                draft = tunnel.dpi
                portText = String(draft.port)
                domainsText = draft.extraDomains.joined(separator: "\n")
                #if CELLULAR
                operatorName = CellularProfile.operators.first(where: { $0.apn == draft.apn })?.name ?? ""
                #endif
                loaded = true
            }
        }
    }

    private func save() {
        if let p = Int(portText), (1...65535).contains(p) { draft.port = p }
        draft.extraDomains = domainsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        draft.apn = draft.apn.trimmingCharacters(in: .whitespaces)
        draft.enabled = tunnel.dpi.enabled
        tunnel.dpi = draft
        tunnel.applyDPI()
    }
}
