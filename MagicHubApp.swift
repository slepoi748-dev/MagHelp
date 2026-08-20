//
//  MagicHubApp.swift
//  Точка входа Magic Hub.
//

import SwiftUI

@main
struct MagicHubApp: App {
    @StateObject private var core = MagicCore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(core)
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
        }
    }
}

// MARK: - Корневой экран

struct RootView: View {
    @EnvironmentObject var core: MagicCore
    @State private var tab = 0
    @State private var openedApp: MagicApp? = nil

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            TabView(selection: $tab) {
                AppLauncherView(openedApp: $openedApp)
                    .tabItem { Label("Приложения", systemImage: "square.grid.2x2.fill") }.tag(0)

                DevicesView()
                    .tabItem { Label("Устройства", systemImage: "antenna.radiowaves.left.and.right") }.tag(1)

                LinksView()
                    .tabItem { Label("Связи", systemImage: "arrow.triangle.branch") }.tag(2)

                SettingsView()
                    .tabItem { Label("Пульт", systemImage: "dot.radiowaves.left.and.right") }.tag(3)
            }
            .tint(Color(hex: "#4C8DFF"))
        }
        // Приложение открывается НА ВЕСЬ ЭКРАН — ни браузера, ни вкладок
        .fullScreenCover(item: $openedApp) { app in
            AppContainerView(app: app) { openedApp = nil }
                .environmentObject(core)
        }
    }
}

// MARK: - Контейнер приложения (полный экран)

struct AppContainerView: View {
    let app: MagicApp
    let onClose: () -> Void
    @EnvironmentObject var core: MagicCore
    @State private var showBar = false

    var body: some View {
        ZStack(alignment: .top) {
            MagicWebView(app: app, core: core)
                .ignoresSafeArea()

            // Скрытая зона выхода: свайп вниз от верхнего края.
            // Никаких видимых кнопок — зритель ничего не замечает.
            Color.clear
                .frame(height: 60)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { v in
                            if v.translation.height > 40 { withAnimation { showBar.toggle() } }
                        }
                )

            if showBar {
                HStack {
                    Button { onClose() } label: {
                        Label("Выход", systemImage: "xmark.circle.fill")
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(core.remoteConnected ? .green : .gray).frame(width: 8, height: 8)
                        if let b = core.remoteBattery { Text("\(b)%") }
                    }.font(.caption)
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .transition(.move(edge: .top))
            }
        }
        .statusBarHidden(true)
        .onDisappear { core.setIdleContext() }   // возвращаем контроль Hub
    }
}

// MARK: - Лаунчер приложений

struct AppLauncherView: View {
    @EnvironmentObject var core: MagicCore
    @Binding var openedApp: MagicApp?
    @State private var showAdd = false

    private let cols = [GridItem(.adaptive(minimum: 105), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                RemoteStatusBar()
                    .padding(.horizontal).padding(.top, 6)

                LazyVGrid(columns: cols, spacing: 20) {
                    ForEach(core.apps) { app in
                        Button { openedApp = app } label: {
                            VStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .fill(Color(hex: app.color).opacity(0.22))
                                        .frame(width: 74, height: 74)
                                    Image(systemName: app.icon)
                                        .font(.system(size: 30, weight: .medium))
                                        .foregroundStyle(Color(hex: app.color))
                                }
                                Text(app.name)
                                    .font(.caption).foregroundStyle(.primary)
                                    .lineLimit(1)
                                if app.trusted {
                                    Text("Magic").font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Button { showAdd = true } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 74, height: 74)
                                Image(systemName: "plus").font(.title2).foregroundStyle(.secondary)
                            }
                            Text("Добавить").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Magic")
            .sheet(isPresented: $showAdd) { AddAppView() }
        }
    }
}

// MARK: - Полоса состояния пульта

struct RemoteStatusBar: View {
    @EnvironmentObject var core: MagicCore

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(core.remoteConnected ? .green : .gray)
                .frame(width: 9, height: 9)
                .shadow(color: core.remoteConnected ? .green : .clear, radius: 4)

            Text(core.remoteConnected ? "Пульт \(core.remoteName)" : "Пульт не подключён")
                .font(.subheadline)

            if core.beaconActive {
                Text("ТРЮК").font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.25))
                    .clipShape(Capsule())
            }

            Spacer()

            if let b = core.remoteBattery {
                Label("\(b)%", systemImage: "battery.100")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !core.remoteConnected {
                Button("Искать") { core.startScanRemote() }.font(.caption)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Добавление дружественного приложения

struct AddAppView: View {
    @EnvironmentObject var core: MagicCore
    @Environment(\.dismiss) var dismiss
    @State private var manifestURL = ""
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Манифест приложения") {
                    TextField("https://site.ru/magic-app.json", text: $manifestURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Загрузить") { load() }
                }
                if !status.isEmpty {
                    Section { Text(status).font(.caption) }
                }
                Section("Как это работает") {
                    Text("Разработчик размещает файл magic-app.json на своём сайте. Hub читает его и узнаёт: название приложения, какие команды оно понимает и какие режимы поддерживает. После этого пульт управляет приложением автоматически.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Добавить приложение")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }

    private func load() {
        guard let url = URL(string: manifestURL) else { status = "Некорректная ссылка"; return }
        status = "Загрузка…"
        URLSession.shared.dataTask(with: url) { data, _, err in
            DispatchQueue.main.async {
                guard let data = data, err == nil else { status = "Ошибка загрузки"; return }
                do {
                    let m = try JSONDecoder().decode(AppManifest.self, from: data)
                    let app = MagicApp(id: m.app_id, name: m.name, url: m.url,
                                       icon: m.icon ?? "app.fill", color: m.color ?? "#4C8DFF",
                                       protocolVersion: m.protocol_version ?? 2,
                                       commands: m.commands ?? [], trusted: true)
                    if !core.apps.contains(where: { $0.id == app.id }) { core.apps.append(app) }
                    status = "Добавлено: \(m.name)"
                    core.addLog("Приложение добавлено: \(m.name)")
                } catch {
                    status = "Манифест не распознан"
                }
            }
        }.resume()
    }
}

struct AppManifest: Codable {
    let app_id: String
    let name: String
    let url: String
    let icon: String?
    let color: String?
    let protocol_version: Int?
    let commands: [String]?
}

// MARK: - Утилита цвета

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red:   Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8)  & 0xFF) / 255,
                  blue:  Double(v & 0xFF) / 255,
                  opacity: 1)
    }
}
