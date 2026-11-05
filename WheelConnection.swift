import Foundation
import CoreBluetooth
import Combine

struct NearbyWheel: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    var protocolHint: String? = nil
}

// CBCentralManager uses the main queue; all delegates, published state and user
// actions run on that queue. No commands are replayed after a disconnect.
final class WheelConnection: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = WheelConnection()
    private static let services = [CBUUID(string: "FFE0"),CBUUID(string: "FFE5"),CBUUID(string: WheelTransport.uartService)]
    private static let savedIDKey = "wheel.sherman.peripheral"
    private static let autoKey = "wheel.sherman.reconnect"
    @Published private(set) var nearby: [NearbyWheel] = []
    @Published private(set) var scanning = false
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var name = "Колесо"
    @Published private(set) var status = "Колесо не подключено"
    @Published private(set) var sample: WheelTelemetry?
    @Published private(set) var batteryReading: WheelBatteryReading?
    @Published private(set) var alarm: WheelAlarmState?
    @Published private(set) var lightOn: Bool?
    @Published private(set) var lightReadAt: Date?
    @Published private(set) var pending: String?
    @Published var message: String?
    @Published private(set) var settings = WheelSettingsSnapshot()
    @Published private(set) var settingsRevision = 0
    @Published private(set) var automaticConnection = UserDefaults.standard.bool(forKey: "wheel.sherman.reconnect")
    private var central: CBCentralManager?
    private var devices: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var decoder = WheelDriverHub()
    private var notifyCharacteristic: CBCharacteristic?
    private var pendingServices = Set<CBUUID>()
    private var protocolTimer: Timer?
    private var protocolTick = 0
    private var protocolQueries: [Data] = []
    private var waitingQueryResponse = false
    private var identificationSent = false
    private var queryID = UUID()
    private var nextQueryAt = Date.distantPast
    private var desiredID: UUID?
    private var reconnectEnabled = false
    private var scanRequested = false
    private var scanID = UUID()
    private var connectionID = UUID()
    private var pendingCommand: PendingCommand?
    private var demo = false
    private var reconnectID = UUID()
    private var writeChunks: [Data] = []
    private var waitingWriteResponse = false
    private var sentAllAt: Date?
    private var requireStoppedForWrite = false
    private struct PendingCommand {
        let id: UUID
        let target: Target
        let sentAt: Date
    }
    private enum Target { case alarm(Bool), light(Bool), settings([WheelSettingKey: Int], Int?) }

    var hasSavedWheel: Bool { UserDefaults.standard.string(forKey: Self.savedIDKey) != nil }
    var supported: Bool { connected && sample?.compatibleAlarm == true }
    var lightSupported: Bool { connected && sample?.canSetLight == true && characteristic != nil }
    func controlsAvailable(at date: Date = Date()) -> Bool { supported && (demo || sample?.isFresh(at: date) == true) && pending == nil }
    func alarmIsFresh(at date: Date = Date()) -> Bool { sample?.isFresh(at: date) == true && alarm != nil }
    func lightIsFresh(at date: Date = Date()) -> Bool { lightReadAt.map { date.timeIntervalSince($0) <= 15 } == true }

    override private init() { super.init() }
    // Called when the user opens the wheel module. Merely displaying offline demo
    // never initializes CoreBluetooth and never asks for Bluetooth permission.
    func activate(demo value: Bool) {
        WheelPhoneAlarmMonitor.shared.activate(demo: value)
        if !value { WheelSpeedPreferences.shared.selectWheel(id: UserDefaults.standard.string(forKey: Self.savedIDKey)) }
        if value {
            if demo { return }
            stopSession(clearSaved: false); demo = true
            name = "Моноколесо · демо"; connected = true; connecting = false; status = "Демо · без подключения по Bluetooth"
            sample = WheelTelemetry(receivedAt: Date(), speed: 0, pwm: 0, voltage: 144.5, temperature: 32, firmware: 6010, tripMeters: 0, totalMeters: 12340, compatibleAlarm: true, alarm: .off, lightOn: false, model: "Демонстрационное колесо")
            alarm = .off; lightOn = false; lightReadAt = Date(); loadDemoSettings()
            return
        }
        if demo { demo = false; clearReadings(); connected = false; status = "Колесо не подключено" }
        // First-time permission is requested by the explicit Connect button.
        if hasSavedWheel && UserDefaults.standard.bool(forKey: Self.autoKey) { automaticConnection = true; reconnectEnabled = true; ensureCentral(); if central?.state == .poweredOn { reconnectSaved() } }
    }
    func scan() {
        guard !demo else { return }
        message = nil; scanRequested = true; ensureCentral()
        if central?.state == .poweredOn { beginScan() }
    }
    func reconnect() {
        guard !demo else { return }
        message = nil; automaticConnection = true; reconnectEnabled = true; UserDefaults.standard.set(true, forKey: Self.autoKey)
        ensureCentral(); if central?.state == .poweredOn { reconnectSaved() }
    }
    func connect(_ id: UUID) {
        guard !demo, let central, central.state == .poweredOn, let value = devices[id] else { return }
        central.stopScan(); scanning = false; scanRequested = false; scanID = UUID(); nearby = []
        if let old = peripheral, old.identifier != id { old.delegate = nil; central.cancelPeripheralConnection(old) }
        desiredID = id; reconnectEnabled = true; automaticConnection = true
        UserDefaults.standard.set(id.uuidString, forKey: Self.savedIDKey)
        UserDefaults.standard.set(true, forKey: Self.autoKey)
        beginConnection(value)
    }
    func disconnect() {
        if demo { connected = false; clearReadings(); status = "Демонстрационное колесо отключено"; return }
        stopSession(clearSaved: false)
        UserDefaults.standard.set(false, forKey: Self.autoKey); automaticConnection = false
    }
    private func stopSession(clearSaved: Bool) {
        reconnectEnabled = false; scanRequested = false; desiredID = nil; reconnectID = UUID(); connectionID = UUID(); scanID = UUID()
        central?.stopScan(); scanning = false
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil; characteristic = nil; connected = false; connecting = false; clearReadings()
        if clearSaved { UserDefaults.standard.removeObject(forKey: Self.savedIDKey) }
        status = "Колесо отключено"
    }
    private func ensureCentral() {
        guard central == nil else { return }
        reconnectEnabled = UserDefaults.standard.bool(forKey: Self.autoKey)
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionRestoreIdentifierKey: "ru.local.vvcourier.sherman", CBCentralManagerOptionShowPowerAlertKey: true])
    }
    private func beginScan() {
        guard let central, central.state == .poweredOn, !scanning else { return }
        nearby = []; devices = [:]; scanning = true; status = "Ищем колесо рядом…"
        central.scanForPeripherals(withServices: Self.services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // Results become selectable immediately. Keep this explicit search
        // active until selection/cancel; no fixed 12-second waiting window.
        scanID = UUID()
    }
    private func reconnectSaved() {
        guard reconnectEnabled, let central, central.state == .poweredOn, !connecting, !connected,
              let saved = UserDefaults.standard.string(forKey: Self.savedIDKey), let id = UUID(uuidString: saved) else { return }
        desiredID = id
        if let value = central.retrievePeripherals(withIdentifiers: [id]).first { beginConnection(value) }
        else { scanRequested = true; beginScan() }
    }
    private func beginConnection(_ value: CBPeripheral) {
        guard let central else { return }
        central.stopScan(); scanning = false; scanRequested = false; scanID = UUID(); nearby = []
        clearReadings(); peripheral = value; value.delegate = self; characteristic = nil
        WheelSpeedPreferences.shared.selectWheel(id: value.identifier.uuidString, name: value.name)
        name = value.name ?? "Колесо"; connected = false; connecting = true; status = "Подключаемся к колесу…"
        connectionID = UUID()
        // CoreBluetooth keeps this request pending until the remembered wheel
        // becomes available. A timer must not cancel the owner's auto-connect.
        central.connect(value, options: nil)
    }

    private func clearReadings() {
        WheelPhoneAlarmMonitor.shared.disconnected()
        WheelRideStore.shared.disconnected()
        batteryReading = nil
        queryID = UUID(); nextQueryAt = .distantPast
        protocolTimer?.invalidate(); protocolTimer = nil; protocolQueries = []; waitingQueryResponse = false; identificationSent = false; notifyCharacteristic = nil; pendingServices = []
        decoder = WheelDriverHub(); sample = nil; alarm = nil; lightOn = nil; lightReadAt = nil; settings = WheelSettingsSnapshot(); settingsRevision += 1; clearPendingWrite()
    }
    func setAlarm(_ enabled: Bool) {
        guard controlsAvailable(), let sample, (demo || sample.isFresh(age: 2)), alarm != nil else { message = "Сначала дождись свежего состояния сигнализации от колеса."; return }
        guard !enabled || abs(sample.speed) < 0.1 else { message = "Останови колесо и переведи его в парковку P."; return }
        if alarm?.enabled == enabled { message = enabled ? "Колесо уже на охране." : "Охрана уже выключена."; return }
        send(ShermanLCommands.alarm(enabled), target: .alarm(enabled), label: enabled ? "Включаем охрану…" : "Снимаем с охраны…")
    }
    func setLight(_ enabled: Bool) {
        guard connected, sample?.isFresh() == true || demo, pending == nil, let sample, lightSupported || demo,
              let command = demo ? ShermanLCommands.light(enabled) : decoder.lightCommand(enabled, sample: sample) else { message = "Для этой модели нет подтверждённой команды фары или свежей связи."; return }
        send(command, target: .light(enabled), label: enabled ? "Включаем фару…" : "Выключаем фару…")
    }
    func setAutomaticConnection(_ enabled: Bool) {
        automaticConnection = enabled
        if demo { return }
        UserDefaults.standard.set(enabled, forKey: Self.autoKey)
        reconnectEnabled = enabled; reconnectID = UUID()
        if enabled { ensureCentral(); if central?.state == .poweredOn { reconnectSaved() } }
        else if connecting && !connected { stopSession(clearSaved: false) }
    }
    func stopSearch() {
        scanRequested = false; scanID = UUID(); central?.stopScan(); scanning = false
        status = connected ? "Подключено" : "Поиск остановлен"
    }
    func settingsValue(_ key: WheelSettingKey, at date: Date = Date()) -> Int? { demo ? settings.values[key] : settings.value(key, at: date) }
    private func loadDemoSettings() {
        let values: [WheelSettingKey: Int] = [.hardness: 80,.pedalAngle: 0,.tiltbackSpeed: 40,.pwmTiltback: 80,.speedAlarm: 35,.displayBrightness: 70,.keyVolume: 50,.lateralCutoff: 60,.chargeLimit: 1512,.stockAssist: 50,.dipCompensation: 50,.units: 0,.voltageTrim: 0,.lowBattery: 0,.highSpeed: 0,.transport: 0,.assistEnabled: 0,.assistAcceleration: 50,.assistAccelerationLimit: 20,.assistBraking: 50,.assistBrakingLimit: 20,.pidEnabled: 0,.pidKa: 2280,.pidKg: 1170,.pidKc: 180]
        settings.merge(WheelSettingsPage(receivedAt: Date(), kind: 0x50, values: values, invalid: [], pidGeneration: 1, pidResult: 1)); settingsRevision += 1
    }
    func applySettings(_ changes: [WheelSettingKey: Int], baseline: [WheelSettingKey: Int]) {
        guard controlsAvailable(), let sample, (demo || sample.isFresh(age: 2)), abs(sample.speed) < 0.1 else { message = "Для настроек останови колесо, включи парковку P и дождись свежей телеметрии."; return }
        var current: [WheelSettingKey: Int] = [:]
        for key in WheelSettingKey.allCases { if let value = settingsValue(key) { current[key] = value } }
        guard changes.allSatisfy({ current[$0.key] != nil && baseline[$0.key] == current[$0.key] }) else { message = "Состояние настроек изменилось или устарело. Обнови черновик по данным колеса перед применением."; return }
        do {
            let token = UInt16.random(in: 1...UInt16.max)
            let plan = try WheelSettingsPlan(changes: changes, current: current, token: token)
            sendFrames(plan.frames, target: .settings(plan.expected, settings.pidGeneration), label: "Применяем настройки…", requireStopped: true)
        } catch { message = error.localizedDescription }
    }
    private func clearPendingWrite() {
        pending = nil; pendingCommand = nil; writeChunks = []; waitingWriteResponse = false; sentAllAt = nil; requireStoppedForWrite = false
    }
    private func send(_ data: Data, target: Target, label: String) { sendFrames([data], target: target, label: label, requireStopped: false) }
    private func sendFrames(_ frames: [Data], target: Target, label: String, requireStopped: Bool) {
        guard pending == nil else { return }
        if demo {
            switch target {
            case .alarm(let enabled): alarm = enabled ? .armed : .off
            case .light(let enabled): lightOn = enabled; lightReadAt = Date()
            case .settings(let values, _): settings.merge(WheelSettingsPage(receivedAt: Date(), kind: 0x50, values: values, invalid: [], pidGeneration: (settings.pidGeneration ?? 0) + 1, pidResult: 1)); settingsRevision += 1
            }
            message = "Демо: действие выполнено только на экране."; return
        }
        guard let peripheral, let characteristic, peripheral.state == .connected, !frames.isEmpty else { message = "Нет подключения к колесу."; return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let chunkSize = min(20, peripheral.maximumWriteValueLength(for: type))
        guard chunkSize > 0 else { message = "Bluetooth пока не готов отправить команду."; return }
        let command = PendingCommand(id: UUID(), target: target, sentAt: Date()); pendingCommand = command; pending = label; message = nil; sentAllAt = nil
        requireStoppedForWrite = requireStopped
        writeChunks = frames.flatMap { frame in stride(from: 0, to: frame.count, by: chunkSize).map { Data(frame[$0..<min($0 + chunkSize, frame.count)]) } }
        sendNextChunk()
        DispatchQueue.main.asyncAfter(deadline: .now() + (requireStopped ? 20 : 8)) { [weak self] in
            guard let self, self.pendingCommand?.id == command.id else { return }
            self.clearPendingWrite()
            switch target {
            case .alarm(let enabled): self.message = enabled ? "Колесо не подтвердило охрану. Переведи его в P и проверь состояние перед повтором." : "Снятие охраны не подтверждено. Проверь связь и состояние колеса."
            case .light: self.message = "Новое состояние фары от колеса не получено. Проверь связь перед повтором."
            case .settings: self.message = "Не все настройки подтверждены колесом. Часть значений могла примениться: проверь текущие значения перед повтором."
            }
        }
    }
    private func sendNextChunk() {
        guard pendingCommand != nil, !waitingWriteResponse, !waitingQueryResponse, protocolQueries.isEmpty else { return }
        guard let peripheral, let characteristic, peripheral.state == .connected else { clearPendingWrite(); message = "Связь оборвалась. Проверь текущие настройки перед повтором."; return }
        if requireStoppedForWrite && (sample?.isFresh(age: 2) != true || abs(sample?.speed ?? 1) >= 0.1) { clearPendingWrite(); message = "Настройка остановлена: нет свежего подтверждения остановки колеса."; return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        while !writeChunks.isEmpty {
            if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            let chunk = writeChunks.removeFirst()
            if type == .withResponse { waitingWriteResponse = true }
            peripheral.writeValue(chunk, for: characteristic, type: type)
            if type == .withResponse { return }
        }
        if sentAllAt == nil { sentAllAt = Date() }
    }
    private func confirmPending(_ sample: WheelTelemetry) {
        guard let command = pendingCommand, let sentAllAt, sample.receivedAt > sentAllAt else { return }
        let matched: Bool
        switch command.target {
        case .alarm(let enabled): matched = sample.compatibleAlarm && sample.alarm.map { $0.enabled == enabled } == true
        case .light(let enabled): matched = sample.lightOn == enabled
        case .settings(let expected, let generation): matched = settings.confirms(expected, after: sentAllAt, oldPIDGeneration: generation)
        }
        if matched { clearPendingWrite(); message = "Колесо подтвердило действие." }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: if scanRequested { beginScan() } else { reconnectSaved() }
        case .poweredOff: status = "Bluetooth выключен"; connected = false; connecting = false; scanning = false; clearReadings()
        case .unauthorized: status = "Нет доступа к Bluetooth"; message = "Разреши Bluetooth для VV Courier в настройках iPhone."; connected = false; connecting = false; scanning = false; clearReadings()
        case .unsupported: status = "Bluetooth недоступен на этом устройстве"
        default: status = "Проверяем Bluetooth…"
        }
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard UserDefaults.standard.bool(forKey: Self.autoKey),
              let saved = UserDefaults.standard.string(forKey: Self.savedIDKey), let id = UUID(uuidString: saved),
              let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where: { $0.identifier == id }) else { return }
        desiredID = id; reconnectEnabled = true; peripheral = restored; restored.delegate = self
        name = restored.name ?? "Колесо"; connecting = true
        if restored.state == .connected { restored.discoverServices(Self.services) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        devices[peripheral.identifier] = peripheral
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        var hint = services.contains(CBUUID(string: WheelTransport.uartService)) ? "UART · протокол уточнится при подключении" : "Последовательный BLE · модель проверится по данным"
        if let manufacturer, manufacturer.count >= 2 { hint += String(format: " · ID %04X", UInt16(manufacturer[0]) | UInt16(manufacturer[1]) << 8) }
        let item = NearbyWheel(id: peripheral.identifier, name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Bluetooth-устройство", rssi: RSSI.intValue, protocolHint: hint)
        nearby.removeAll { $0.id == item.id }; nearby.append(item); nearby.sort { $0.rssi > $1.rssi }
        if reconnectEnabled && desiredID == item.id { connect(item.id) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { central.cancelPeripheralConnection(peripheral); return }
        name = peripheral.name ?? "Колесо"; status = "Получаем данные колеса…"; peripheral.discoverServices(Self.services)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connecting = false; connected = false; status = "Не удалось подключиться"; message = error?.localizedDescription; scheduleReconnect()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        let interruptedWrite = pendingCommand != nil
        connected = false; connecting = false; characteristic = nil; clearReadings(); status = "Связь с колесом потеряна"
        if interruptedWrite { message = "Связь оборвалась во время команды. Проверь состояние и текущие настройки колеса перед повтором." }
        if reconnectEnabled { scheduleReconnect() }
    }
    private func scheduleReconnect() {
        guard reconnectEnabled, !demo else { return }
        let id = UUID(); reconnectID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.reconnectID == id, self.reconnectEnabled else { return }; self.reconnectSaved()
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else { fail("Колесо не предоставило поддерживаемый сервис телеметрии."); return }
        pendingServices = Set(services.map(\.uuid))
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        pendingServices.remove(service.uuid)
        guard error == nil else { fail("Не удалось прочитать каналы Bluetooth."); return }
        guard pendingServices.isEmpty else { return }
        let channels = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
        let transport: WheelTransport
        if channels.contains(where: { $0.uuid == CBUUID(string: WheelTransport.inMotionV2.notify) }) { transport = .inMotionV2 }
        else if channels.contains(where: { $0.uuid == CBUUID(string: "FFE4") }) && channels.contains(where: { $0.uuid == CBUUID(string: "FFE9") }) { transport = .inMotionV1 }
        else { transport = .serial }
        guard let notify = channels.first(where: { $0.uuid == CBUUID(string: transport.notify) && ($0.properties.contains(.notify) || $0.properties.contains(.indicate)) }) else { fail("Поддерживаемый канал показаний не найден. Модель пока не поддерживается."); return }
        characteristic = channels.first(where: { $0.uuid == CBUUID(string: transport.write) && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)) })
        if transport != .serial && characteristic == nil { fail("Для чтения InMotion нужен отдельный канал запросов."); return }
        decoder.configure(transport); notifyCharacteristic = notify; peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier, characteristic.uuid == notifyCharacteristic?.uuid else { return }
        guard error == nil, characteristic.isNotifying else { fail("Не удалось включить телеметрию колеса."); return }
        queueQueries(decoder.initialQueries)
        protocolTick = 0; protocolTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.pending == nil, self.protocolQueries.isEmpty, !self.waitingQueryResponse else { return }
            self.protocolTick += 1
            if self.sample == nil && self.protocolTick % 20 == 0 { self.queueQueries(self.decoder.initialQueries) }
            self.queueQueries(self.decoder.pollQueries(tick: self.protocolTick))
        }
        RunLoop.main.add(timer, forMode: .common); protocolTimer = timer
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier, characteristic.uuid == notifyCharacteristic?.uuid, error == nil, let value = characteristic.value else { return }
        let packets = decoder.append(value)
        if packets.isEmpty && sample == nil { status = decoder.diagnostic }
        for packet in packets {
            let reading = packet.telemetry
            sample = reading; connecting = false; connected = true; status = "Подключено · " + reading.family.title
            name = reading.modelName
            if let battery = reading.batteryReading { batteryReading = battery }
            WheelPhoneAlarmMonitor.shared.receive(reading)
            if !demo { WheelRideStore.shared.receive(reading, wheelID: peripheral.identifier.uuidString) }
            alarm = reading.compatibleAlarm ? reading.alarm : nil
            if let on = reading.lightOn { lightOn = on; lightReadAt = reading.receivedAt }
            if let page = packet.settings { settings.merge(page); settingsRevision += 1 }
            confirmPending(reading)
        }
        if !packets.isEmpty && !identificationSent { identificationSent = true; queueQueries(decoder.identificationQueries) }
    }
    private func queueQueries(_ frames: [Data]) {
        guard pending == nil, protocolQueries.isEmpty, !waitingQueryResponse, characteristic != nil else { return }
        // One serial queue shared by read-only handshake/poll and user writes.
        // Never replay queries after disconnect or interleave a command frame.
        protocolQueries = frames.flatMap { data in stride(from: 0, to: data.count, by: 20).map { Data(data[$0..<min($0+20,data.count)]) } }
        sendNextQuery()
    }
    private func sendNextQuery() {
        guard !waitingQueryResponse, !waitingWriteResponse, let peripheral, let characteristic else { return }
        let delay = nextQueryAt.timeIntervalSinceNow
        if delay > 0 {
            let id = queryID
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in guard self?.queryID == id else { return }; self?.sendNextQuery() }
            return
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if !protocolQueries.isEmpty {
            if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            let data = protocolQueries.removeFirst()
            if type == .withResponse { waitingQueryResponse = true }
            nextQueryAt = Date().addingTimeInterval(0.05)
            peripheral.writeValue(data, for: characteristic, type: type)
            if type == .withoutResponse {
                let id = queryID
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in guard self?.queryID == id else { return }; self?.sendNextQuery() }
            }
            return
        }
        if pending != nil { sendNextChunk() }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let error { waitingQueryResponse = false; protocolQueries = []; clearPendingWrite(); message = "Ошибка канала записи: " + error.localizedDescription; return }
        if waitingQueryResponse { waitingQueryResponse = false; sendNextQuery() }
        else { waitingWriteResponse = false; sendNextChunk() }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }; if !protocolQueries.isEmpty { sendNextQuery() } else { sendNextChunk() }
    }
    private func fail(_ text: String) {
        reconnectEnabled = false; automaticConnection = false; UserDefaults.standard.set(false, forKey: Self.autoKey); connected = false; connecting = false; clearReadings(); status = text; message = text
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    }
}
