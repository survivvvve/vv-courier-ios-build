import Foundation

enum WheelSettingKey: String, CaseIterable, Identifiable {
    case hardness, pedalAngle, tiltbackSpeed, pwmTiltback, speedAlarm, displayBrightness, keyVolume, lateralCutoff, chargeLimit, stockAssist, dipCompensation, units, voltageTrim, lowBattery, highSpeed, transport
    case assistEnabled, assistAcceleration, assistAccelerationLimit, assistBraking, assistBrakingLimit
    case pidEnabled, pidKa, pidKg, pidKc
    var id: String { rawValue }
    var isCustom: Bool { [.assistEnabled, .assistAcceleration, .assistAccelerationLimit, .assistBraking, .assistBrakingLimit, .pidEnabled, .pidKa, .pidKg, .pidKc].contains(self) }
    var isPID: Bool { [.pidEnabled, .pidKa, .pidKg, .pidKc].contains(self) }
    var isAssist: Bool { isCustom && !isPID }
    var title: String {
        switch self {
        case .hardness: return "Жёсткость педалей"; case .pedalAngle: return "Угол педалей"; case .tiltbackSpeed: return "Тилтбэк по скорости"; case .pwmTiltback: return "Тилтбэк по ШИМ"; case .speedAlarm: return "Сигнал по скорости"; case .displayBrightness: return "Яркость дисплея"; case .keyVolume: return "Громкость кнопок"; case .lateralCutoff: return "Боковой угол отключения"; case .chargeLimit: return "Предел зарядки"; case .stockAssist: return "Штатный ассист"; case .dipCompensation: return "Компенсация наклона"; case .units: return "Единицы дисплея"; case .voltageTrim: return "Поправка напряжения"; case .lowBattery: return "Старт при низком заряде"; case .highSpeed: return "Высокоскоростной режим"; case .transport: return "Транспортный режим"
        case .assistEnabled: return "Раздельный ассист"; case .assistAcceleration: return "Сила разгона"; case .assistAccelerationLimit: return "Предел наклона при разгоне"; case .assistBraking: return "Сила торможения"; case .assistBrakingLimit: return "Предел наклона при торможении"
        case .pidEnabled: return "Пользовательский ПИД"; case .pidKa: return "Ka · упор"; case .pidKg: return "Kg · успокоение"; case .pidKc: return "Kc · подхват"
        }
    }
    var range: ClosedRange<Int> {
        switch self {
        case .hardness, .displayBrightness, .keyVolume, .stockAssist, .dipCompensation, .assistAcceleration, .assistBraking: return 0...100
        case .pedalAngle: return -80...80
        case .tiltbackSpeed, .speedAlarm: return 10...100
        case .pwmTiltback: return 30...95
        case .lateralCutoff: return 35...75
        case .chargeLimit: return 1450...1512
        case .voltageTrim: return -15...15
        case .assistAccelerationLimit: return 20...45
        case .assistBrakingLimit: return 20...60
        case .pidKa: return 1800...4400
        case .pidKg: return 800...1250
        case .pidKc: return -1400...600
        default: return 0...1
        }
    }
    var allowsDisabled: Bool { [.tiltbackSpeed, .pwmTiltback, .speedAlarm].contains(self) }
    var isToggle: Bool { range == 0...1 && self != .units }
    var step: Int { self == .displayBrightness ? 5 : 1 }
    func accepts(_ value: Int) -> Bool { (allowsDisabled && value == 200) || range.contains(value) }
    func formatted(_ value: Int) -> String {
        if allowsDisabled && value == 200 { return "Отключено" }
        switch self {
        case .pedalAngle, .assistAccelerationLimit, .assistBrakingLimit: return String(format: "%.1f°", Double(value) / 10)
        case .chargeLimit: return String(format: "%.1f В", Double(value) / 10)
        case .voltageTrim: return String(format: "%+.1f%%", Double(value) / 10)
        case .tiltbackSpeed, .speedAlarm: return "\(value) км/ч"
        case .lateralCutoff: return "\(value)°"
        case .units: return value == 0 ? "км/ч" : "мили/ч"
        case .pidKa, .pidKg, .pidKc: return "\(value)"
        default: return isToggle ? (value == 0 ? "Выключено" : "Включено") : "\(value)%"
        }
    }
    var stockIndex: Int? {
        switch self {
        case .hardness: return 5; case .pedalAngle: return 6; case .tiltbackSpeed: return 7; case .pwmTiltback: return 8; case .speedAlarm: return 9; case .displayBrightness: return 10; case .transport: return 12; case .units: return 13; case .lowBattery: return 15; case .voltageTrim: return 14; case .highSpeed: return 16; case .lateralCutoff: return 17; case .keyVolume: return 18; case .chargeLimit: return 19; case .stockAssist: return 21; case .dipCompensation: return 23; default: return nil
        }
    }
}

struct WheelSettingsPage: Equatable {
    let receivedAt: Date
    let kind: UInt8
    let values: [WheelSettingKey: Int]
    let invalid: Set<WheelSettingKey>
    var pidGeneration: Int? = nil
    var pidResult: Int? = nil
    // Called only after CRC validation of a complete realtime packet.
    static func decode(_ frame: [UInt8], at date: Date, compatible: Bool) -> WheelSettingsPage? {
        guard compatible, frame.count > 47 else { return nil }
        let page = frame[46]
        var values: [WheelSettingKey: Int] = [:], invalid = Set<WheelSettingKey>()
        func record(_ key: WheelSettingKey, _ value: Int?) {
            if let value, key.accepts(value) { values[key] = value } else { invalid.insert(key) }
        }
        if page == 8 && frame.count >= 75 {
            for (key, offset) in [(WheelSettingKey.hardness,50),(.pedalAngle,51),(.tiltbackSpeed,52),(.pwmTiltback,53),(.speedAlarm,54),(.displayBrightness,55),(.transport,57),(.units,58),(.voltageTrim,59),(.lowBattery,60),(.highSpeed,61),(.lateralCutoff,62),(.keyVolume,63),(.stockAssist,66),(.dipCompensation,68)] {
                let byte = frame[offset]
                let value = byte == 0x80 ? nil : [.pedalAngle,.voltageTrim].contains(key) ? Int(Int8(bitPattern: byte)) : Int(byte)
                record(key, value)
            }
            let charge = frame[64], base = frame[65]
            record(.chargeLimit, charge == 0x80 || base != 145 ? nil : 1450 + Int(charge))
            return WheelSettingsPage(receivedAt: date, kind: page, values: values, invalid: invalid)
        }
        if page == 0x50 && frame.count >= 115 {
            let mode = frame[47]
            record(.pidEnabled, mode <= 2 ? (mode == 0 ? 0 : 1) : nil)
            for (key, offset) in [(WheelSettingKey.pidKa,56),(.pidKg,58),(.pidKc,60)] {
                let raw = UInt16(frame[offset]) << 8 | UInt16(frame[offset + 1])
                record(key, Int(Int16(bitPattern: raw)))
            }
            record(.assistAcceleration, Int(frame[107]))
            let packed = frame[108]
            record(.assistEnabled, Int(packed >> 6))
            record(.assistAccelerationLimit, Int(packed & 0x3F))
            record(.assistBraking, Int(frame[109]))
            record(.assistBrakingLimit, Int(frame[110]))
            return WheelSettingsPage(receivedAt: date, kind: page, values: values, invalid: invalid, pidGeneration: Int(frame[104]) << 8 | Int(frame[105]), pidResult: Int(frame[103]))
        }
        return nil
    }
}

struct WheelSettingsSnapshot {
    private(set) var values: [WheelSettingKey: Int] = [:]
    private(set) var timestamps: [WheelSettingKey: Date] = [:]
    private(set) var pidGeneration: Int?
    private(set) var pidResult: Int?
    private(set) var pidReceivedAt: Date?
    mutating func merge(_ page: WheelSettingsPage) {
        for key in page.invalid { values.removeValue(forKey: key); timestamps.removeValue(forKey: key) }
        for (key, value) in page.values { values[key] = value; timestamps[key] = page.receivedAt }
        if page.kind == 0x50 { pidGeneration = page.pidGeneration; pidResult = page.pidResult; pidReceivedAt = page.receivedAt }
    }
    func value(_ key: WheelSettingKey, at date: Date = Date(), maxAge: TimeInterval = 15) -> Int? {
        guard let time = timestamps[key], date.timeIntervalSince(time) >= 0, date.timeIntervalSince(time) <= maxAge else { return nil }
        return values[key]
    }
    func confirms(_ desired: [WheelSettingKey: Int], after sent: Date, oldPIDGeneration: Int?) -> Bool {
        guard !desired.isEmpty else { return false }
        for (key, wanted) in desired {
            guard values[key] == wanted, let time = timestamps[key], time > sent else { return false }
        }
        if desired.keys.contains(where: \.isPID) {
            guard pidResult == 1, let generation = pidGeneration, generation != oldPIDGeneration, let time = pidReceivedAt, time > sent else { return false }
        }
        return true
    }
}

struct WheelSettingsPlan {
    let expected: [WheelSettingKey: Int]
    let frames: [Data]
    init(changes: [WheelSettingKey: Int], current: [WheelSettingKey: Int], token: UInt16) throws {
        guard !changes.isEmpty, changes.allSatisfy({ $0.key.accepts($0.value) }) else { throw WheelSettingsError(message: "Проверь выбранные значения настроек.") }
        var desired = current; desired.merge(changes) { _, new in new }
        var frames: [Data] = [], expected = changes
        let stock = changes.filter { !$0.key.isCustom }
        if !stock.isEmpty {
            let last = stock.keys.compactMap(\.stockIndex).max()!
            var payload = [UInt8](repeating: 0x80, count: last + 1); payload[0] = 0; payload[1] = 2
            for (key, var value) in stock {
                if value == 200 { value = key == .pwmTiltback ? 96 : 101 }
                if key == .chargeLimit { value -= 1450 }
                payload[key.stockIndex!] = UInt8(truncatingIfNeeded: value)
            }
            frames.append(ShermanLCommands.settingsFrame(payload))
        }
        if changes.keys.contains(where: \.isAssist) {
            let keys: [WheelSettingKey] = [.assistEnabled,.assistAcceleration,.assistAccelerationLimit,.assistBraking,.assistBrakingLimit]
            guard keys.allSatisfy({ desired[$0].map($0.accepts) == true }) else { throw WheelSettingsError(message: "Дождись полного состояния раздельного ассиста.") }
            // All fields change only while stopped/in parking. Disable first so
            // no intermediate combination becomes an active partial profile.
            frames.append(ShermanLCommands.customSetting(0x31, value: 0))
            for (key, selector) in zip(keys.dropFirst(), UInt8(0x32)...0x35) { frames.append(ShermanLCommands.customSetting(selector, value: desired[key]!)) }
            frames.append(ShermanLCommands.customSetting(0x31, value: desired[.assistEnabled]!))
            for key in keys { expected[key] = desired[key] }
        }
        if changes.keys.contains(where: \.isPID) {
            let keys: [WheelSettingKey] = [.pidEnabled,.pidKa,.pidKg,.pidKc]
            guard keys.allSatisfy({ desired[$0].map($0.accepts) == true }) else { throw WheelSettingsError(message: "Дождись полного состояния ПИД-регулятора.") }
            frames.append(ShermanLCommands.customSetting(0x10, value: Int(token)))
            for (key, selector) in zip([WheelSettingKey.pidKa,.pidKg,.pidKc,.pidEnabled], UInt8(0x11)...0x14) { frames.append(ShermanLCommands.customSetting(selector, value: desired[key]!)) }
            frames.append(ShermanLCommands.customSetting(0x15, value: Int(token)))
            for key in keys {
                if key == .pidEnabled || desired[.pidEnabled] != 0 { expected[key] = desired[key] }
                else { expected.removeValue(forKey: key) }
            }
        }
        self.expected = expected; self.frames = frames
    }
}
struct WheelSettingsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension ShermanLCommands {
    static func settingsFrame(_ payload: [UInt8]) -> Data { frame(payload) }
    static func customSetting(_ selector: UInt8, value: Int) -> Data {
        frame([0,0x61,4,selector,3,UInt8(truncatingIfNeeded: value),UInt8(truncatingIfNeeded: value >> 8)])
    }
}
