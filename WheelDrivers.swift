import Foundation

// Independent implementations of documented wire facts. Primary references:
// github.com/eried/eucplanet/tree/main/docs/protocols (Veteran/Begode/KingSong)
// A device name is a hint, never permission for a brand-specific control write.
enum WheelTransport: Equatable {
    case serial, inMotionV1, inMotionV2
    static let serialService = "FFE0"
    static let legacyWriteService = "FFE5"
    static let uartService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    var notify: String { switch self { case .serial: return "FFE1"; case .inMotionV1: return "FFE4"; case .inMotionV2: return "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" } }
    var write: String { switch self { case .serial: return "FFE1"; case .inMotionV1: return "FFE9"; case .inMotionV2: return "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" } }
}

enum WheelBytes {
    static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i+1]) }
    static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i+1]) << 8 }
    static func signedBE(_ b: [UInt8], _ i: Int) -> Int16 { Int16(bitPattern: be16(b,i)) }
    static func signedLE(_ b: [UInt8], _ i: Int) -> Int16 { Int16(bitPattern: le16(b,i)) }
    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(be16(b,i)) << 16 | UInt32(be16(b,i+2)) }
    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(le16(b,i)) | UInt32(le16(b,i+2)) << 16 }
    static func signed32(_ b: [UInt8], _ i: Int) -> Int32 { Int32(bitPattern: le32(b,i)) }
    static func swappedLE(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(le16(b,i)) << 16 | UInt32(le16(b,i+2)) }
    static func saneSpeed(_ value: Double) -> Bool { value.isFinite && abs(value) <= 200 }
    static func fresh<T>(_ reading: (T,Date)?, at date: Date, age: Double = 3) -> T? { reading.flatMap { date.timeIntervalSince($0.1) >= 0 && date.timeIntervalSince($0.1) <= age ? $0.0 : nil } }
}

struct WheelDriverHub {
    private(set) var family: WheelFamily?
    private var transport: WheelTransport = .serial
    private var veteran = WheelFrameDecoder(acceptLegacy: true)
    private var begode = BegodeWheelDecoder()
    private var kingSong = KingSongWheelDecoder()
    private var motion = InMotionWheelDecoder()
    private(set) var diagnostic = "Ожидаем данные для определения протокола."
    mutating func configure(_ transport: WheelTransport) {
        self = WheelDriverHub(); self.transport = transport
        if transport == .inMotionV1 { family = .inMotionV1; motion = InMotionWheelDecoder(legacy: true) }
        if transport == .inMotionV2 { family = .inMotionV2; motion = InMotionWheelDecoder(legacy: false) }
    }
    mutating func append(_ data: Data, at date: Date = Date()) -> [WheelDecodedPacket] {
        if family == nil && transport == .serial {
            // FFE0 is shared by three manufacturers. Run bounded, independent
            // framers until a complete VALID live frame identifies the family;
            // an isolated magic sequence in garbage/payload cannot lock it.
            let v = veteran.appendPackets(data, at: date)
            let b = begode.append(data, at: date)
            let k = kingSong.append(data, at: date)
            if !v.isEmpty { family = .veteran; diagnostic = v.last!.telemetry.modelName; return v }
            if !b.isEmpty { family = .begode; diagnostic = b.last!.modelName; return b.map { WheelDecodedPacket(telemetry: $0, settings: nil) } }
            if !k.isEmpty { family = .kingSong; diagnostic = k.last!.modelName; return k.map { WheelDecodedPacket(telemetry: $0, settings: nil) } }
            return []
        }
        let input = data
        let packets: [WheelDecodedPacket]
        switch family {
        case .veteran: packets = veteran.appendPackets(input, at: date)
        case .begode: packets = begode.append(input, at: date).map { WheelDecodedPacket(telemetry: $0, settings: nil) }
        case .kingSong: packets = kingSong.append(input, at: date).map { WheelDecodedPacket(telemetry: $0, settings: nil) }
        case .inMotionV1, .inMotionV2:
            packets = motion.append(input, at: date).map { WheelDecodedPacket(telemetry: $0, settings: nil) }
            diagnostic = motion.diagnostic
        case nil: packets = []
        }
        if let sample = packets.last?.telemetry { diagnostic = sample.modelName + " · " + sample.family.title }
        return packets
    }
    var initialQueries: [Data] {
        switch transport {
        case .serial: return []
        case .inMotionV1: return [InMotionWheelDecoder.legacyQuery(0x0F550114, remote: true),InMotionWheelDecoder.legacyQuery(0x0F550113)]
        case .inMotionV2: return InMotionWheelDecoder.modernIdentificationQueries
        }
    }
    var identificationQueries: [Data] {
        switch family { case .begode: return [Data([0x56]),Data([0x4E])]; case .kingSong: return [KingSongWheelDecoder.query(0x9B)]; default: return [] }
    }
    mutating func pollQueries(tick: Int) -> [Data] {
        switch transport {
        case .serial: return []
        case .inMotionV1: return [InMotionWheelDecoder.legacyQuery(tick % 20 == 0 ? 0x0F550114 : 0x0F550113, remote: tick % 20 == 0)]
        case .inMotionV2:
            return motion.modernPollQueries(tick: tick)
        }
    }
    func lightCommand(_ on: Bool, sample: WheelTelemetry) -> Data? {
        guard sample.family == family else { return nil }
        if sample.compatibleAlarm { return ShermanLCommands.light(on) }
        if sample.family == .begode { return Data([on ? 0x51 : 0x45]) }
        if sample.family == .veteran, WheelTelemetry.veteranModels[sample.firmware / 1000] != nil { return Data((on ? "SetLightON" : "SetLightOFF").utf8) }
        // Other families remain read-only: no uncertain readback or auth/beam
        // variant is treated as a successful control operation.
        return nil
    }
}

struct BegodeWheelDecoder {
    private var bytes: [UInt8] = []
    private var text = ""
    private var model: String?
    private var firmware: String?
    private var imu: Int?
    private var total: (UInt32,Date)?
    private var voltage: (Double,Date)?
    private var pwm: (Double,Date)?
    private var current: (Double,Date)?
    private var light: (Bool,Date)?
    mutating func append(_ data: Data, at date: Date) -> [WheelTelemetry] {
        text += String(data.map { $0 >= 32 && $0 <= 126 || $0 == 10 || $0 == 13 ? Character(UnicodeScalar($0)) : "\n" })
        if text.count > 512 { text = String(text.suffix(256)) }
        if text.contains("MPU6500") { imu = 6500 } else if text.contains("MPU6050") { imu = 6050 }
        for prefix in ["GW","JN","CF","BF"] { if let range = text.range(of: prefix) { firmware = String(text[range.lowerBound...].prefix(24).prefix { !$0.isNewline && $0.asciiValue != 0 }); break } }
        if let range = text.range(of: "NAME ") { model = String(text[range.upperBound...].prefix(28).prefix { !$0.isNewline && $0.asciiValue != 0 }) }
        bytes += data; if bytes.count > 4096 { bytes.removeFirst(bytes.count-512) }
        var results: [WheelTelemetry] = []
        while bytes.count >= 24 {
            guard bytes[0] == 0x55 && bytes[1] == 0xAA && Array(bytes[20...23]) == [0x5A,0x5A,0x5A,0x5A] else { bytes.removeFirst(); continue }
            let b = Array(bytes.prefix(24)); bytes.removeFirst(24)
            switch b[18] {
            case 4:
                total = (WheelBytes.be32(b,2),date)
                if b[15] & 3 <= 2 { light = (b[15] & 3 != 0,date) }
            case 1:
                let value = Double(WheelBytes.be16(b,6)) / 10
                if (20...260).contains(value) { voltage = (value,date) }
            case 7:
                let value = abs(Double(WheelBytes.signedBE(b,8))) / 100
                if value <= 110 { pwm = (value,date) }
                let amps = -Double(WheelBytes.signedBE(b,2)) / 100
                if abs(amps) <= 400 { current = (amps,date) }
            case 0:
                let speed = Double(WheelBytes.signedBE(b,4)) * 3.6 / 100
                guard WheelBytes.saneSpeed(speed), (2000...9000).contains(WheelBytes.be16(b,2)), b[19] == 0x18 else { continue }
                let phase = Double(WheelBytes.signedBE(b,10)) / 100
                guard abs(phase) <= 400 else { continue }
                let rawTemp = Double(WheelBytes.signedBE(b,12))
                let temperature = imu.map { rawTemp / ($0 == 6500 ? 333.87 : 340) + ($0 == 6500 ? 21 : 36.53) }
                let volts = WheelBytes.fresh(voltage, at: date, age: 10)
                let amps = WheelBytes.fresh(current, at: date)
                let battery = amps.map { WheelBatteryReading(receivedAt: current!.1, current: $0, power: nil) }
                var sample = WheelTelemetry(receivedAt: date, speed: speed, pwm: WheelBytes.fresh(pwm, at: date), voltage: volts, temperature: temperature.flatMap { (-40...150).contains($0) ? $0 : nil }, firmware: 0, tripMeters: UInt32(WheelBytes.be16(b,8)), totalMeters: WheelBytes.fresh(total, at: date), compatibleAlarm: false, alarm: nil, lightOn: WheelBytes.fresh(light, at: date), phaseCurrent: phase)
                sample.family = .begode; sample.model = model; sample.firmwareLabel = firmware; sample.integrity = .framingOnly
                if let battery { sample.batteryReading = WheelBatteryReading(receivedAt: battery.receivedAt, current: battery.current, power: volts.map { $0 * battery.current }) }
                results.append(sample)
            default: break
            }
        }
        return results
    }
}

struct KingSongWheelDecoder {
    private var bytes: [UInt8] = []
    private var model: String?
    private var version: String?
    private var trip: (UInt32,Date)?
    private var pwm: (Double,Date)?
    static func query(_ command: UInt8) -> Data { var b = [UInt8](repeating: 0, count: 20); b[0] = 0xAA; b[1] = 0x55; b[16] = command; b[17] = 0x14; b[18] = 0x5A; b[19] = 0x5A; return Data(b) }
    mutating func append(_ data: Data, at date: Date) -> [WheelTelemetry] {
        bytes += data; if bytes.count > 4096 { bytes.removeFirst(bytes.count-512) }
        var results: [WheelTelemetry] = []
        while bytes.count >= 20 {
            guard bytes[0] == 0xAA && bytes[1] == 0x55 && bytes[18] == 0x5A && bytes[19] == 0x5A else { bytes.removeFirst(); continue }
            let b = Array(bytes.prefix(20)); bytes.removeFirst(20)
            switch b[16] {
            case 0xBB:
                let name = String(bytes: b[2...15].prefix { $0 != 0 }, encoding: .ascii) ?? ""
                if name.hasPrefix("KS-") || name.hasPrefix("ROCKW") || name == "RW" {
                    var parts = name.split(separator: "-").map(String.init)
                    if let last = parts.last, let raw = Double(last), parts.count > 2 { version = String(format: "%.2f",raw/100); parts.removeLast() }
                    model = parts.joined(separator: "-")
                }
            case 0xB9: trip = (WheelBytes.swappedLE(b,2),date)
            case 0xF5: if b[15] <= 100 { pwm = (Double(b[15]),date) }
            case 0xA9:
                let speed = Double(WheelBytes.le16(b,4))/100
                let volts = Double(WheelBytes.le16(b,2))/100
                let amps = Double(WheelBytes.signedLE(b,10))/100
                guard WheelBytes.saneSpeed(speed), (20...260).contains(volts), abs(amps) <= 400 else { continue }
                // Temperature scale differs by firmware in primary references;
                // do NOT label an uncertain raw field as degrees Celsius.
                var sample = WheelTelemetry(receivedAt: date, speed: speed, pwm: WheelBytes.fresh(pwm, at: date), voltage: volts, temperature: nil, firmware: 0, tripMeters: WheelBytes.fresh(trip, at: date, age: 10), totalMeters: WheelBytes.swappedLE(b,6), compatibleAlarm: false, alarm: nil, lightOn: nil, batteryReading: WheelBatteryReading(receivedAt: date, current: amps, power: volts * amps))
                sample.family = .kingSong; sample.model = model; sample.firmwareLabel = version; sample.integrity = .framingOnly
                if let model {
                    let cells: Double?
                    if ["KS-S20","KS-S22"].contains(model) { cells = 30 }
                    else if model == "KS-S19" { cells = 24 }
                    else if model == "KS-F18P" { cells = 36 }
                    else if model == "KS-F22P" { cells = 42 }
                    else if ["KS-18L","KS-18LH","KS-18LY","KS-16X","KS-16XF","KS-S16","KS-S16P","KS-S18","RW"].contains(model) { cells = 20 }
                    else { cells = nil }
                    if let cells { sample.reportedBattery = (volts/cells - 3.10)/(4.15-3.10)*100 }
                }
                results.append(sample)
            default: break
            }
        }
        return results
    }
}
