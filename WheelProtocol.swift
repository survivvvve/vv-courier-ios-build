import Foundation

enum WheelFamily: String, Codable { case veteran, begode, kingSong, inMotionV1, inMotionV2
    var title: String { switch self { case .veteran: return "LeaperKim / NOSFET"; case .begode: return "Begode / Extreme Bull"; case .kingSong: return "KingSong"; case .inMotionV1: return "InMotion · legacy"; case .inMotionV2: return "InMotion" } }
}
enum WheelFrameIntegrity: String { case crc32, checksum, framingOnly }

// Independent implementation from the public Veteran wire-format description and
// the user's exact Sherman L 006.0.10 image, SHA256 d82deab1...57f305d6.
// Commands were checked through that image's receiver/dispatcher in Unicorn.
// Reference framing: https://github.com/eried/eucplanet/blob/main/docs/protocols/veteran.md
// No firmware image or third-party adapter source is included in the app.
struct WheelTelemetry: Equatable {
    let receivedAt: Date
    let speed: Double
    let pwm: Double?
    let voltage: Double?
    let temperature: Double?
    let firmware: Int
    let tripMeters: UInt32?
    let totalMeters: UInt32?
    let compatibleAlarm: Bool
    let alarm: WheelAlarmState?
    let lightOn: Bool?
    // Public Veteran realtime layout; current is motor phase current, NOT the
    // battery current. Never multiply it by battery voltage to claim pack power.
    var phaseCurrent: Double? = nil
    var pitch: Double? = nil
    var batteryReading: WheelBatteryReading? = nil
    var family: WheelFamily = .veteran
    var model: String? = nil
    var firmwareLabel: String? = nil
    var reportedBattery: Double? = nil
    var batteryIsEstimated = true
    var integrity: WheelFrameIntegrity = .crc32
    var odometerQuantumMeters: Double = 1
    var isShermanL: Bool { family == .veteran && firmware / 1000 == 6 }
    var version: String { firmwareLabel ?? (family == .veteran && firmware > 0 ? String(format: "%03d.%01d.%02d", firmware / 1000, (firmware % 1000) / 100, firmware % 100) : "Не определена") }
    var modelName: String {
        if let model { return model }
        if family == .veteran { return Self.veteranModels[firmware / 1000] ?? "LeaperKim / NOSFET" }
        return family.title
    }
    static let veteranModels = [0:"Sherman / Sherman Max",1:"Sherman / Sherman Max",2:"Abrams",3:"Sherman S",4:"Patton",5:"Lynx",6:"Sherman L",7:"Patton S",8:"Oryx",9:"Lynx S",42:"NOSFET Apex",43:"NOSFET Aero",44:"NOSFET Aeon",45:"NOSFET Xeno"]
    var estimatedBattery: Int? {
        if let reportedBattery, reportedBattery.isFinite { return Int(min(100, max(0, reportedBattery.rounded()))) }
        guard family == .veteran, let voltage else { return nil }
        let model = firmware / 1000
        let range: (Double, Double)
        switch model { case 0...3: range = (79.35,98.70); case 4,7,43,45: range = (99.18,123.37); case 5,6,9,42,44: range = (119.02,148.05); case 8: range = (138.86,172.72); default: return nil }
        return Int(min(100, max(0, ((voltage - range.0) / (range.1 - range.0) * 100).rounded())))
    }
    var canSetLight: Bool { compatibleAlarm || family == .begode || (family == .veteran && Self.veteranModels[firmware / 1000] != nil) }
    func isFresh(at date: Date = Date(), age: TimeInterval = 3) -> Bool { date.timeIntervalSince(receivedAt) >= 0 && date.timeIntervalSince(receivedAt) <= age }
}

struct WheelBatteryReading: Equatable {
    let receivedAt: Date
    let current: Double
    let power: Double?
    func isFresh(at date: Date = Date()) -> Bool {
        let age = date.timeIntervalSince(receivedAt)
        return age >= 0 && age <= 10
    }
}

enum WheelAlarmState: UInt8, Equatable {
    case off = 0, armed = 1, warning = 2, sounding = 3
    var enabled: Bool { self != .off }
    var title: String {
        switch self { case .off: return "Охрана выключена"; case .armed: return "На охране"; case .warning: return "Обнаружено движение"; case .sounding: return "Сработала сигнализация" }
    }
}

struct WheelDecodedPacket {
    let telemetry: WheelTelemetry
    let settings: WheelSettingsPage?
}

struct WheelFrameDecoder {
    private var bytes: [UInt8] = []
    private(set) var rejectedFrames = 0
    var acceptLegacy = false
    init(acceptLegacy: Bool = false) { self.acceptLegacy = acceptLegacy }
    private var crcLatched = false
    mutating func reset() { bytes = []; rejectedFrames = 0; crcLatched = false }
    mutating func append(_ data: Data, at date: Date = Date()) -> [WheelTelemetry] {
        appendPackets(data, at: date).map(\.telemetry)
    }
    mutating func appendPackets(_ data: Data, at date: Date = Date()) -> [WheelDecodedPacket] {
        bytes.append(contentsOf: data)
        if bytes.count > 4096 { bytes.removeFirst(bytes.count - 512) }
        var results: [WheelDecodedPacket] = []
        while bytes.count >= 4 {
            guard Array(bytes.prefix(3)) == [0xDC, 0x5A, 0x5C] else { bytes.removeFirst(); continue }
            let length = Int(bytes[3])
            let legacy = acceptLegacy && !crcLatched && [32,34].contains(length)
            guard legacy || (length >= 47 && length <= 200) else { rejectedFrames += 1; bytes.removeFirst(); continue }
            guard bytes.count >= length + 4 else { break }
            let frame = Array(bytes.prefix(length + 4))
            guard legacy ? (frame[22] == 0 && frame[23] <= 1 && [0,7].contains(frame[30])) : Self.crc32(Array(frame.prefix(length))) == Self.u32(frame, length),
                  var sample = Self.decode(frame, date: date) else { rejectedFrames += 1; bytes.removeFirst(); continue }
            if !legacy { crcLatched = true } else { sample.integrity = .framingOnly }
            bytes.removeFirst(length + 4)
            results.append(WheelDecodedPacket(telemetry: sample, settings: legacy ? nil : WheelSettingsPage.decode(frame, at: date, compatible: sample.compatibleAlarm)))
        }
        return results
    }
    private static func decode(_ b: [UInt8], date: Date) -> WheelTelemetry? {
        let voltage = Double(u16(b, 4)) / 100
        let speed = Double(Int16(bitPattern: u16(b, 6))) / 10
        let temperature = Double(Int16(bitPattern: u16(b, 18))) / 100
        let pwm: Double? = b.count >= 36 && Int(u16(b, 28)) / 1000 >= 2 ? Double(u16(b, 34)) / 100 : nil
        let version = Int(u16(b, 28))
        guard (50...250).contains(voltage), abs(speed) <= 200, (-40...150).contains(temperature), (pwm.map { $0 <= 110 } ?? true) else { return nil }
        // Exact firmware 006.0.10 injects LC 03 23 at 40..43, alarm byte at45.
        // 0 off, 1 armed, 2 warning, 3 siren. Only use this known schema.
        let compatible = b.count >= 50 && version == 6010 && Array(b[40...43]) == [0x4C, 0x43, 0x03, 0x23]
        let alarm = compatible ? WheelAlarmState(rawValue: b[45]) : nil
        // Configuration page8:47 reads the real lamp flag from this firmware.
        let light: Bool? = b.count >= 75 && b[46] == 8 && [0, 1].contains(b[47]) ? b[47] == 1 : nil
        // Offsets/scales agree with the public Veteran protocol and the local
        // independent adapter: phase current16/10 A, longitudinal angle32/100°.
        let phase = Double(Int16(bitPattern: u16(b, 16))) / 10
        let pitch: Double? = b.count >= 36 ? Double(Int16(bitPattern: u16(b, 32))) / 100 : nil
        var battery: WheelBatteryReading?
        // Only header pages0/4 contain BOTH battery-pack currents. Other pages
        // reuse these offsets for cells/settings. Include no CRC bytes as data.
        if version / 1000 >= 5, b.count >= 77, [0, 4].contains(b[46]), Int(b[3]) >= 73 {
            let pack1 = Double(Int16(bitPattern: u16(b, 69))) / 100
            let pack2 = Double(Int16(bitPattern: u16(b, 71))) / 100
            if abs(pack1) <= 400, abs(pack2) <= 400 {
                let current = pack1 + pack2
                battery = WheelBatteryReading(receivedAt: date, current: current, power: voltage * current)
            }
        }
        return WheelTelemetry(receivedAt: date, speed: speed, pwm: pwm, voltage: voltage, temperature: temperature, firmware: version,
                              tripMeters: wordSwapped(b, 8), totalMeters: wordSwapped(b, 12), compatibleAlarm: compatible, alarm: alarm, lightOn: light,
                              phaseCurrent: abs(phase) <= 400 ? phase : nil, pitch: pitch.flatMap { abs($0) <= 180 ? $0 : nil }, batteryReading: battery)
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1 }
        }
        return value ^ 0xFFFFFFFF
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
    private static func wordSwapped(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i + 2)) << 16 | UInt32(u16(b, i)) }
}

enum ShermanLCommands {
    // Receiver 0x08009816 copies payload to decoded+0x12; custom dispatcher
    // 0x08019C34 requires selector0x61 and schema3. Alarm handler0x08018F88:
    // class3, subcommand1, LE16 boolean. Firmware itself enforces parking(P).
    static func alarm(_ enabled: Bool) -> Data { frame([0, 0x61, 3, 1, 3, enabled ? 1 : 0, 0]) }
    // Stock dispatcher0x08009670 selector2, first field ->0x08007160 ->
    // lamp byte0x200001AD; omitted settings remain sentinel0x80 in receiver.
    static func light(_ enabled: Bool) -> Data { frame([0, 2, enabled ? 1 : 0]) }
    static func frame(_ payload: [UInt8]) -> Data {
        var b: [UInt8] = [0x4C, 0x64, 0x41, 0x70, UInt8(payload.count + 9)] + payload
        let crc = WheelFrameDecoder.crc32(b)
        b += [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)]
        return Data(b)
    }
}
