//
//  MagicCore.swift
//  Magic Hub — ядро экосистемы
//
//  Содержит: Magic Protocol, менеджер пульта (S3), менеджер устройств,
//  реестр приложений и маршрутизатор событий.
//

import Foundation
import CoreBluetooth
import Combine

// MARK: - UUID экосистемы

enum MagicUUID {
    // Пульт Hidra S3 (совпадает с прошивкой v1.97)
    static let remoteService = CBUUID(string: "7A4D2B10-9C3E-4F18-A6D2-5B1E8C7F0A01")
    static let remoteCmd     = CBUUID(string: "7A4D2B11-9C3E-4F18-A6D2-5B1E8C7F0A01")
    static let remoteEvt     = CBUUID(string: "7A4D2B12-9C3E-4F18-A6D2-5B1E8C7F0A01")

    // Magic Devices — твои устройства (конфетти, свет, серво…)
    static let deviceService = CBUUID(string: "7A4D2B20-9C3E-4F18-A6D2-5B1E8C7F0A01")
    static let deviceCmd     = CBUUID(string: "7A4D2B21-9C3E-4F18-A6D2-5B1E8C7F0A01")
    static let deviceEvt     = CBUUID(string: "7A4D2B22-9C3E-4F18-A6D2-5B1E8C7F0A01")
}

// MARK: - Модель приложения экосистемы

struct MagicApp: Identifiable, Codable, Hashable {
    var id: String            // app_id, например "notes"
    var name: String
    var url: String           // https://… или local://notes/index.html
    var icon: String          // SF Symbol или эмодзи
    var color: String         // hex
    var protocolVersion: Int
    var commands: [String]
    var trusted: Bool         // дружественное приложение с манифестом

    static let builtIn: [MagicApp] = [
        MagicApp(id: "notes", name: "Magic Notes",
                 url: "local://notes/index.html",
                 icon: "note.text", color: "#4C8DFF",
                 protocolVersion: 2,
                 commands: ["UP","DOWN","SELECT","BACK","RESET"],
                 trusted: true)
    ]
}

// MARK: - Модель устройства

struct DeviceSetting: Identifiable, Codable, Hashable {
    var id: String { key }
    var key: String
    var label: String
    var type: String          // "int" | "bool" | "enum"
    var value: Double
    var min: Double?
    var max: Double?
    var options: [String]?
}

struct MagicDevice: Identifiable {
    var id: String            // device_id, например "confetti-001"
    var name: String
    var type: String          // "confetti" | "light" | "servo" …
    var firmware: String
    var battery: Int
    var online: Bool
    var modes: [String]
    var currentMode: String
    var commands: [String]
    var settings: [DeviceSetting]
    var peripheral: CBPeripheral?
    var cmdChar: CBCharacteristic?
}

// MARK: - Связь между устройствами (device-to-device через Hub)

struct DeviceLink: Identifiable, Codable, Hashable {
    var id = UUID()
    var sourceId: String      // устройство-источник или "remote"
    var event: String         // событие источника
    var targetId: String      // устройство-получатель
    var command: String       // команда получателю
    var value: Double?
    var enabled: Bool = true
}

// MARK: - Ядро

final class MagicCore: NSObject, ObservableObject {

    // Пульт
    @Published var remoteConnected = false
    @Published var remoteName      = "—"
    @Published var remoteBattery: Int? = nil
    @Published var remoteFirmware  = "—"
    @Published var beaconActive    = false

    // Устройства
    @Published var devices: [MagicDevice] = []
    @Published var links: [DeviceLink] = []

    // Приложения
    @Published var apps: [MagicApp] = MagicApp.builtIn
    @Published var activeApp: MagicApp? = nil

    // Журнал (для отладки на сцене)
    @Published var log: [String] = []

    // Колбэк: сообщение от пульта уходит в открытое web-приложение
    var onRemoteMessage: ((String) -> Void)?
    var onStatusChange:  ((String) -> Void)?

    private var central: CBCentralManager!
    private var remotePeripheral: CBPeripheral?
    private var remoteCmdChar: CBCharacteristic?
    private var scanningForDevices = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "magic-hub-central"])
        loadLinks()
    }

    // MARK: Журнал
    func addLog(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.insert("[\(t)] \(s)", at: 0)
        if log.count > 200 { log.removeLast() }
    }

    // MARK: - Пульт

    func startScanRemote() {
        guard central.state == .poweredOn else { addLog("Bluetooth выключен"); return }
        addLog("Поиск пульта…")
        central.scanForPeripherals(withServices: [MagicUUID.remoteService], options: nil)
    }

    func disconnectRemote() {
        if let p = remotePeripheral { central.cancelPeripheralConnection(p) }
    }

    /// Отправить сообщение Magic Protocol на пульт
    func sendToRemote(_ dict: [String: Any]) {
        guard let char = remoteCmdChar,
              let p = remotePeripheral,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        p.writeValue(data, for: char, type: .withoutResponse)
    }

    func setContext(app: String, mode: String) {
        sendToRemote(["t": "CTX", "app": app, "mode": mode])
    }

    /// Пока ни одно приложение не открыто, Hub держит собственный контекст "hub".
    /// Это ОБЯЗАТЕЛЬНО: прошивка шлёт события кнопок только при заданном контексте.
    /// Без этого связи «кнопка пульта → устройство» не сработают.
    func setIdleContext() {
        setContext(app: "hub", mode: "idle")
        display("MAGIC", "gotov")
    }

    func display(_ l1: String, _ l2: String) {
        sendToRemote(["t": "DISP", "l1": l1, "l2": l2])
    }

    // MARK: - Устройства

    func startScanDevices() {
        guard central.state == .poweredOn else { return }
        scanningForDevices = true
        addLog("Поиск устройств…")
        central.scanForPeripherals(withServices: [MagicUUID.deviceService], options: nil)
    }

    func stopScanDevices() {
        scanningForDevices = false
        central.stopScan()
    }

    func sendToDevice(_ id: String, _ dict: [String: Any]) {
        guard let idx = devices.firstIndex(where: { $0.id == id }),
              let char = devices[idx].cmdChar,
              let p = devices[idx].peripheral,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        p.writeValue(data, for: char, type: .withoutResponse)
        addLog("→ \(id): \(dict["c"] ?? dict["t"] ?? "?")")
    }

    func deviceCommand(_ id: String, _ command: String, value: Double? = nil) {
        var msg: [String: Any] = ["t": "DCMD", "c": command]
        if let v = value { msg["v"] = v }
        sendToDevice(id, msg)
    }

    func deviceSetMode(_ id: String, _ mode: String) {
        sendToDevice(id, ["t": "DMODE", "mode": mode])
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].currentMode = mode }
    }

    func deviceSetSetting(_ id: String, key: String, value: Double) {
        sendToDevice(id, ["t": "DSET", "k": key, "v": value])
        if let i = devices.firstIndex(where: { $0.id == id }),
           let j = devices[i].settings.firstIndex(where: { $0.key == key }) {
            devices[i].settings[j].value = value
        }
    }

    // MARK: - Связи устройств

    func addLink(_ link: DeviceLink) { links.append(link); saveLinks() }
    func removeLink(_ link: DeviceLink) { links.removeAll { $0.id == link.id }; saveLinks() }

    private func saveLinks() {
        if let d = try? JSONEncoder().encode(links) {
            UserDefaults.standard.set(d, forKey: "magic_links")
        }
    }
    private func loadLinks() {
        if let d = UserDefaults.standard.data(forKey: "magic_links"),
           let l = try? JSONDecoder().decode([DeviceLink].self, from: d) { links = l }
    }

    /// Сработало событие — проверяем связи и выполняем цепочки
    func fireEvent(source: String, event: String) {
        for link in links where link.enabled && link.sourceId == source && link.event == event {
            deviceCommand(link.targetId, link.command, value: link.value)
            addLog("Связь: \(source).\(event) → \(link.targetId).\(link.command)")
        }
    }

    // MARK: - Разбор входящих сообщений

    private func handleRemoteMessage(_ raw: String) {
        addLog("← пульт: \(raw)")
        onRemoteMessage?(raw)                       // прокидываем в web-приложение

        guard let d = raw.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = m["t"] as? String else { return }

        switch t {
        case "HI":
            remoteFirmware = m["fw"] as? String ?? "—"
        case "HB":
            remoteBattery = m["bat"] as? Int
            beaconActive  = (m["bc"] as? Int ?? 0) == 1
        case "EV":
            // событие пульта может запускать связи с устройствами
            if let g = m["g"] as? String {
                if g == "c", let cb = m["cb"] as? String { fireEvent(source: "remote", event: "combo\(cb)") }
                else if let b = m["b"] as? Int { fireEvent(source: "remote", event: "btn\(b)\(g)") }
            }
        default: break
        }
    }

    private func handleDeviceMessage(_ raw: String, from peripheral: CBPeripheral) {
        guard let d = raw.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = m["t"] as? String else { return }

        let devId = m["dev"] as? String ?? peripheral.identifier.uuidString

        switch t {
        case "DHI", "DCAPS":
            var settings: [DeviceSetting] = []
            if let arr = m["set"] as? [[String: Any]] {
                for s in arr {
                    settings.append(DeviceSetting(
                        key:   s["k"] as? String ?? "",
                        label: s["l"] as? String ?? (s["k"] as? String ?? ""),
                        type:  s["ty"] as? String ?? "int",
                        value: s["v"] as? Double ?? 0,
                        min:   s["min"] as? Double,
                        max:   s["max"] as? Double,
                        options: s["opt"] as? [String]))
                }
            }
            if let i = devices.firstIndex(where: { $0.id == devId }) {
                devices[i].modes    = m["modes"] as? [String] ?? devices[i].modes
                devices[i].commands = m["cmds"]  as? [String] ?? devices[i].commands
                if !settings.isEmpty { devices[i].settings = settings }
                devices[i].online = true
            } else {
                devices.append(MagicDevice(
                    id: devId,
                    name: m["name"] as? String ?? devId,
                    type: m["dt"] as? String ?? "generic",
                    firmware: m["fw"] as? String ?? "—",
                    battery: m["bat"] as? Int ?? 0,
                    online: true,
                    modes: m["modes"] as? [String] ?? [],
                    currentMode: m["mode"] as? String ?? "",
                    commands: m["cmds"] as? [String] ?? [],
                    settings: settings,
                    peripheral: peripheral,
                    cmdChar: nil))
            }
            addLog("Устройство: \(devId) готово")

        case "DST", "DHB":
            if let i = devices.firstIndex(where: { $0.id == devId }) {
                if let b = m["bat"] as? Int { devices[i].battery = b }
                if let md = m["mode"] as? String { devices[i].currentMode = md }
            }

        case "DEV":                                  // событие от устройства (датчик и т.п.)
            if let e = m["e"] as? String { fireEvent(source: devId, event: e) }

        default: break
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension MagicCore: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: addLog("Bluetooth готов"); startScanRemote()
        case .poweredOff: addLog("Bluetooth выключен"); remoteConnected = false
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripherals] as? [CBPeripheral] {
            for p in ps { p.delegate = self; if p.identifier == remotePeripheral?.identifier { remotePeripheral = p } }
            addLog("Состояние BLE восстановлено")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        if services.contains(MagicUUID.remoteService) && remotePeripheral == nil {
            remotePeripheral = p
            p.delegate = self
            c.connect(p, options: nil)
            addLog("Найден пульт: \(p.name ?? "Hidra")")
            if !scanningForDevices { c.stopScan() }
        }
        else if services.contains(MagicUUID.deviceService) {
            if !devices.contains(where: { $0.peripheral?.identifier == p.identifier }) {
                p.delegate = self
                c.connect(p, options: nil)
                addLog("Найдено устройство: \(p.name ?? "?")")
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.delegate = self
        if p.identifier == remotePeripheral?.identifier {
            remoteConnected = true
            remoteName = p.name ?? "Hidra"
            p.discoverServices([MagicUUID.remoteService])
            onStatusChange?("connected")
        } else {
            p.discoverServices([MagicUUID.deviceService])
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if p.identifier == remotePeripheral?.identifier {
            remoteConnected = false
            remoteCmdChar = nil
            remotePeripheral = nil
            remoteBattery = nil
            addLog("Пульт отключён")
            onStatusChange?("disconnected")
            startScanRemote()                        // авто-переподключение
        } else if let i = devices.firstIndex(where: { $0.peripheral?.identifier == p.identifier }) {
            devices[i].online = false
            addLog("Устройство \(devices[i].id) отключено")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension MagicCore: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            if s.uuid == MagicUUID.remoteService {
                p.discoverCharacteristics([MagicUUID.remoteCmd, MagicUUID.remoteEvt], for: s)
            } else if s.uuid == MagicUUID.deviceService {
                p.discoverCharacteristics([MagicUUID.deviceCmd, MagicUUID.deviceEvt], for: s)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        var remoteReady = false
        for ch in s.characteristics ?? [] {
            switch ch.uuid {
            case MagicUUID.remoteCmd:
                remoteCmdChar = ch
                remoteReady = true
            case MagicUUID.remoteEvt:
                p.setNotifyValue(true, for: ch)
            case MagicUUID.deviceCmd:
                if let i = devices.firstIndex(where: { $0.peripheral?.identifier == p.identifier }) {
                    devices[i].cmdChar = ch
                } else {
                    devices.append(MagicDevice(id: p.identifier.uuidString,
                                               name: p.name ?? "Устройство",
                                               type: "generic", firmware: "—", battery: 0,
                                               online: true, modes: [], currentMode: "",
                                               commands: [], settings: [],
                                               peripheral: p, cmdChar: ch))
                }
            case MagicUUID.deviceEvt:
                p.setNotifyValue(true, for: ch)
            default: break
            }
        }
        // Контекст ставим ПОСЛЕ того, как характеристика записи готова
        if remoteReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.setIdleContext()
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value, let raw = String(data: d, encoding: .utf8) else { return }
        if ch.uuid == MagicUUID.remoteEvt { handleRemoteMessage(raw) }
        else if ch.uuid == MagicUUID.deviceEvt { handleDeviceMessage(raw, from: p) }
    }
}
