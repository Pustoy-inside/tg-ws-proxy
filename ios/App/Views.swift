import SwiftUI
import UIKit
import NetworkExtension

@main
struct TGWSProxyApp: App {
    @StateObject private var tunnel = TunnelManager()
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
    @EnvironmentObject var tunnel: TunnelManager
    @State private var copied = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { tunnel.isOn },
                        set: { on in Task { if on { await tunnel.start() } else { await tunnel.stop() } } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Прокси для Telegram").font(.headline)
                            Text(tunnel.statusText).font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    if let e = tunnel.lastError {
                        Text(e).font(.footnote).foregroundColor(.red)
                    }
                    if let e = tunnel.proxy.listenError, tunnel.status == .connected {
                        Text("Порт занят или недоступен: \(e)").font(.footnote).foregroundColor(.red)
                    }
                } footer: {
                    Text("Включается как VPN, но трафик телефона через него не идёт: модуль только держит прокси запущенным на 127.0.0.1.")
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

                if tunnel.status == .connected {
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

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundColor(.secondary).monospacedDigit() }
    }
}

func humanBytesApp(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
}

struct SettingsView: View {
    @EnvironmentObject var tunnel: TunnelManager
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
                Toggle("Включать снова автоматически", isOn: $tunnel.autoReconnect)
                Toggle("Подробный журнал", isOn: $draft.verboseLog)
            } footer: {
                Text("Если iOS выгрузит модуль, он включится сам.")
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
        Task { await tunnel.apply() }
    }
}

struct LogView: View {
    @EnvironmentObject var tunnel: TunnelManager
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
                Button { Task { text = await tunnel.fetchLog() } } label: { Image(systemName: "arrow.clockwise") }
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task { text = await tunnel.fetchLog() }
    }
}
