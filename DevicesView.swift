//
//  DevicesView.swift
//  Управление Magic Devices: настройки, режимы, команды, связи.
//

import SwiftUI

// MARK: - Список устройств

struct DevicesView: View {
    @EnvironmentObject var core: MagicCore

    var body: some View {
        NavigationStack {
            List {
                if core.devices.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.largeTitle).foregroundStyle(.secondary)
                            Text("Устройства не найдены")
                                .font(.subheadline)
                            Text("Включите устройство и нажмите «Искать».")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                }

                ForEach(core.devices) { d in
                    NavigationLink(destination: DeviceDetailView(deviceId: d.id)) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(d.online ? Color.green.opacity(0.18) : Color.gray.opacity(0.15))
                                    .frame(width: 40, height: 40)
                                Image(systemName: iconFor(d.type))
                                    .foregroundStyle(d.online ? .green : .gray)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.body)
                                HStack(spacing: 6) {
                                    Text(d.type).font(.caption).foregroundStyle(.secondary)
                                    if !d.currentMode.isEmpty {
                                        Text("· \(d.currentMode)").font(.caption)
                                            .foregroundStyle(Color(hex: "#4C8DFF"))
                                    }
                                }
                            }
                            Spacer()
                            if d.battery > 0 {
                                Text("\(d.battery)%").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Устройства")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { core.startScanDevices() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }

    private func iconFor(_ type: String) -> String {
        switch type {
        case "confetti": return "sparkles"
        case "light":    return "lightbulb.fill"
        case "servo":    return "gearshape.fill"
        case "sound":    return "speaker.wave.2.fill"
        case "sensor":   return "sensor.tag.radiowaves.forward.fill"
        default:         return "cube.fill"
        }
    }
}

// MARK: - Карточка устройства

struct DeviceDetailView: View {
    @EnvironmentObject var core: MagicCore
    let deviceId: String

    private var device: MagicDevice? { core.devices.first { $0.id == deviceId } }

    var body: some View {
        Form {
            if let d = device {

                Section("Состояние") {
                    LabeledContent("Идентификатор", value: d.id)
                    LabeledContent("Тип", value: d.type)
                    LabeledContent("Прошивка", value: d.firmware)
                    LabeledContent("Батарея", value: d.battery > 0 ? "\(d.battery)%" : "—")
                    HStack {
                        Text("Связь")
                        Spacer()
                        Text(d.online ? "на связи" : "нет связи")
                            .foregroundStyle(d.online ? .green : .secondary)
                    }
                }

                if !d.modes.isEmpty {
                    Section("Режим работы") {
                        Picker("Режим", selection: Binding(
                            get: { d.currentMode },
                            set: { core.deviceSetMode(d.id, $0) })) {
                                ForEach(d.modes, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.segmented)
                    }
                }

                if !d.settings.isEmpty {
                    Section("Настройки") {
                        ForEach(d.settings) { s in
                            SettingRow(deviceId: d.id, setting: s)
                        }
                    }
                }

                if !d.commands.isEmpty {
                    Section("Команды") {
                        ForEach(d.commands, id: \.self) { cmd in
                            Button {
                                core.deviceCommand(d.id, cmd)
                            } label: {
                                HStack {
                                    Text(cmd)
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                        .foregroundStyle(Color(hex: "#4C8DFF"))
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        core.deviceCommand(d.id, "STOP")
                    } label: {
                        Label("Аварийная остановка", systemImage: "stop.circle.fill")
                    }
                }
            } else {
                Text("Устройство недоступно")
            }
        }
        .navigationTitle(device?.name ?? "Устройство")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Строка настройки

struct SettingRow: View {
    @EnvironmentObject var core: MagicCore
    let deviceId: String
    let setting: DeviceSetting
    @State private var local: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(setting.label)
                Spacer()
                if setting.type == "int" {
                    Text("\(Int(local))").foregroundStyle(.secondary).font(.callout)
                }
            }

            switch setting.type {
            case "bool":
                Toggle("", isOn: Binding(
                    get: { local > 0.5 },
                    set: { local = $0 ? 1 : 0; core.deviceSetSetting(deviceId, key: setting.key, value: local) }))
                .labelsHidden()

            case "enum":
                Picker("", selection: Binding(
                    get: { Int(local) },
                    set: { local = Double($0); core.deviceSetSetting(deviceId, key: setting.key, value: local) })) {
                        ForEach(Array((setting.options ?? []).enumerated()), id: \.offset) { i, o in
                            Text(o).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)

            default:
                Slider(value: $local,
                       in: (setting.min ?? 0)...(setting.max ?? 100),
                       step: 1,
                       onEditingChanged: { editing in
                           if !editing { core.deviceSetSetting(deviceId, key: setting.key, value: local) }
                       })
            }
        }
        .onAppear { local = setting.value }
    }
}

// MARK: - Связи между устройствами

struct LinksView: View {
    @EnvironmentObject var core: MagicCore
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Связь — это правило: когда происходит событие, автоматически выполняется команда на другом устройстве. Например: нажатие кнопки 1 на пульте запускает конфетти.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if core.links.isEmpty {
                    Text("Связей пока нет").foregroundStyle(.secondary)
                }

                ForEach(core.links) { link in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(sourceLabel(link)).font(.subheadline)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(targetLabel(link)).font(.subheadline)
                                .foregroundStyle(Color(hex: "#4C8DFF"))
                        }
                        Text("\(link.event) → \(link.command)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    idx.map { core.links[$0] }.forEach(core.removeLink)
                }
            }
            .navigationTitle("Связи")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddLinkView() }
        }
    }

    private func sourceLabel(_ l: DeviceLink) -> String {
        l.sourceId == "remote" ? "Пульт" : (core.devices.first { $0.id == l.sourceId }?.name ?? l.sourceId)
    }
    private func targetLabel(_ l: DeviceLink) -> String {
        core.devices.first { $0.id == l.targetId }?.name ?? l.targetId
    }
}

// MARK: - Создание связи

struct AddLinkView: View {
    @EnvironmentObject var core: MagicCore
    @Environment(\.dismiss) var dismiss

    @State private var source = "remote"
    @State private var event  = "btn1s"
    @State private var target = ""
    @State private var command = ""

    private let remoteEvents = [
        ("btn1s", "Кнопка 1 — короткое"), ("btn2s", "Кнопка 2 — короткое"),
        ("btn3s", "Кнопка 3 — короткое"), ("btn4s", "Кнопка 4 — короткое"),
        ("btn1l", "Кнопка 1 — удержание"), ("btn2l", "Кнопка 2 — удержание"),
        ("btn3l", "Кнопка 3 — удержание"), ("btn4l", "Кнопка 4 — удержание"),
        ("combo14", "Кнопки 1+4"), ("combo23", "Кнопки 2+3")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Когда происходит") {
                    Picker("Источник", selection: $source) {
                        Text("Пульт").tag("remote")
                        ForEach(core.devices) { d in Text(d.name).tag(d.id) }
                    }
                    if source == "remote" {
                        Picker("Событие", selection: $event) {
                            ForEach(remoteEvents, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    } else {
                        TextField("Событие устройства", text: $event)
                    }
                }

                Section("Тогда выполнить") {
                    Picker("Устройство", selection: $target) {
                        Text("— выберите —").tag("")
                        ForEach(core.devices) { d in Text(d.name).tag(d.id) }
                    }
                    if let d = core.devices.first(where: { $0.id == target }), !d.commands.isEmpty {
                        Picker("Команда", selection: $command) {
                            Text("— выберите —").tag("")
                            ForEach(d.commands, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        TextField("Команда", text: $command)
                    }
                }

                Section {
                    Button("Создать связь") {
                        core.addLink(DeviceLink(sourceId: source, event: event,
                                                targetId: target, command: command, value: nil))
                        dismiss()
                    }
                    .disabled(target.isEmpty || command.isEmpty)
                }
            }
            .navigationTitle("Новая связь")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}

// MARK: - Настройки и журнал

struct SettingsView: View {
    @EnvironmentObject var core: MagicCore

    var body: some View {
        NavigationStack {
            List {
                Section("Пульт") {
                    LabeledContent("Состояние", value: core.remoteConnected ? "подключён" : "не подключён")
                    LabeledContent("Имя", value: core.remoteName)
                    LabeledContent("Прошивка", value: core.remoteFirmware)
                    LabeledContent("Батарея", value: core.remoteBattery.map { "\($0)%" } ?? "—")
                    if core.beaconActive {
                        Text("Идёт трюк — пульт временно не принимает команды. Это нормально.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button(core.remoteConnected ? "Отключить" : "Искать пульт") {
                        core.remoteConnected ? core.disconnectRemote() : core.startScanRemote()
                    }
                }

                Section("Проверка связи") {
                    Button("Отправить PING") { core.sendToRemote(["t": "PING"]) }
                    Button("Запросить статус") { core.sendToRemote(["t": "STAT"]) }
                    Button("Тест экрана") { core.display("MAGIC", "hub ok") }
                }

                Section("Журнал") {
                    ForEach(core.log.prefix(40), id: \.self) { line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Пульт")
        }
    }
}
