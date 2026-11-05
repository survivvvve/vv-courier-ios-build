import Foundation

// Wire facts only, independently implemented from primary protocol references:
// https://github.com/eried/eucplanet/blob/main/docs/protocols/inmotion_v1.md
// https://github.com/eried/eucplanet/blob/main/docs/protocols/inmotion_v2.md
// Unknown carType does not default to V14/V8: offsets must match a known model.
enum InMotionReadDialect { case unresolved, standard, p6, v6 }
struct InMotionWheelDecoder {
    var legacy = false
    init(legacy: Bool = false) { self.legacy = legacy }
    private var bytes: [UInt8] = []
    private var modelCode: Int?
    private var firmwareLabel: String?
    private(set) var dialect: InMotionReadDialect = .unresolved
    private var lastV6ChallengeTick: Int?
    private var pendingV6Echo: Data?
    private var total: (UInt32,Date)?
    private var lamp: (Bool,Date)?
    private(set) var diagnostic = "Определяем модель InMotion по ответу колеса."
    static let modernModels = [21:"InMotion P6",141:"InMotion V6",61:"InMotion V11",62:"InMotion V11y",71:"InMotion V12 HS",72:"InMotion V12 HT",73:"InMotion V12 Pro",81:"InMotion V13",82:"InMotion V13 Pro",91:"InMotion V14 50GB",92:"InMotion V14 50S",111:"InMotion V12S",121:"InMotion V9",171:"InMotion X1"]
    static let legacyModels = [0:"InMotion R1N",1:"InMotion R1S",2:"InMotion R1CF",3:"InMotion R1AP",4:"InMotion R1EX",5:"InMotion R1 Sample",6:"InMotion R1T",7:"InMotion R10",10:"InMotion V3",11:"InMotion V3C",12:"InMotion V3 Pro",13:"InMotion V3S",20:"InMotion R2",21:"InMotion R2",22:"InMotion R2",23:"InMotion R2",24:"InMotion R2",30:"InMotion R0",50:"InMotion V5",51:"InMotion V5 Plus",52:"InMotion V5F",53:"InMotion V5D",60:"InMotion L6",61:"InMotion Lively",80:"InMotion V8",85:"Solowheel Glide 3",86:"InMotion V8F",87:"InMotion V8S",100:"InMotion V10S",101:"InMotion V10SF",140:"InMotion V10",141:"InMotion V10F",142:"InMotion V10T",143:"InMotion V10FT"]
    static func modernQuery(command: UInt8, data: [UInt8], flags: UInt8 = 0x14) -> Data {
        let b = [flags, UInt8(data.count + 1), command] + data
        return stuffed(b + [b.reduce(0, ^)], legacy: false)
    }
    static func routedQuery(_ command: UInt8, data: [UInt8] = []) -> Data {
        let b = [UInt8(0x16),UInt8(data.count+3),2,0x21,command] + data
        return stuffed(b + [b.reduce(0, ^)], legacy: false)
    }
    static var modernIdentificationQueries: [Data] {
        // All are read requests, not CONTROL/auth/password writes. The V6
        // ignores default info requests; P6 ignores the legacy carType query.
        [modernQuery(command: 2,data: [1],flags: 0x11),
         modernQuery(command: 2,data: [6],flags: 0x11),
         modernQuery(command: 0x10,data: [0,1]),
         modernQuery(command: 2,data: [0,2,1],flags: 0x13),
         modernQuery(command: 2,data: [0,2,2],flags: 0x13),
         modernQuery(command: 2,data: [0,2,6],flags: 0x13),
         routedQuery(6)]
    }
    mutating func modernPollQueries(tick: Int) -> [Data] {
        switch dialect {
        case .p6: return [Self.routedQuery(7)]
        case .v6:
            if let echo = pendingV6Echo { pendingV6Echo = nil; return [echo] }
            // Current capture-backed V6 source requires this session renewal
            // approximately every6s even for continued read-only telemetry.
            if lastV6ChallengeTick.map({ tick - $0 >= 20 }) ?? true {
                lastV6ChallengeTick = tick
                return [Self.modernQuery(command: 2,data: [0,0,2],flags: 0x13)]
            }
            return [Self.routedQuery(tick % 8 == 0 ? 0x11 : 4)]
        case .standard: return [Self.modernQuery(command: tick % 8 == 0 ? 0x11 : 4,data: [])]
        case .unresolved:
            // Renaming a wheel must not force a V14 layout. Read-only probes
            // elicit the distinct P6/V6 response shapes before selecting them.
            switch tick % 3 { case 1: return [Self.routedQuery(7)]; case 2: return [Self.routedQuery(4)]; default: return [Self.modernQuery(command: 4,data: [])] }
        }
    }
    static func legacyQuery(_ id: UInt32, remote: Bool = false) -> Data {
        let b = (0..<4).map { UInt8(truncatingIfNeeded: id >> ($0*8)) } + [UInt8](repeating: 0xFF, count: 8) + [8,5,0,remote ? 1 : 0]
        return stuffed(b + [b.reduce(0, &+)], legacy: true)
    }
    static func stuffed(_ body: [UInt8], legacy: Bool) -> Data {
        var wire: [UInt8] = [0xAA,0xAA]
        for byte in body { if byte == 0xAA || byte == 0xA5 || (legacy && byte == 0x55) { wire.append(0xA5) }; wire.append(byte) }
        if legacy { wire += [0x55,0x55] }
        return Data(wire)
    }
    mutating func append(_ data: Data, at date: Date) -> [WheelTelemetry] {
        bytes += data; if bytes.count > 8192 { bytes.removeFirst(bytes.count-1024) }
        var results: [WheelTelemetry] = []
        while bytes.count >= 4 {
            guard bytes[0] == 0xAA && bytes[1] == 0xAA else { bytes.removeFirst(); continue }
            var body: [UInt8] = [], cursor = 2, consumed: Int?, invalid = false
            while cursor < bytes.count {
                var byte = bytes[cursor]; cursor += 1
                // Current primary encoder leaves the final XOR byte raw;
                // prose describes escaping it. Accept BOTH at the exact known
                // checksum position, never unescaped header bytes in payload.
                if !legacy, body.count >= 2, body.count == Int(body[1]) + 2,
                   (byte == 0xAA || byte == 0xA5), body.reduce(0, ^) == byte {
                    body.append(byte); consumed = cursor; break
                }
                if byte == 0xA5 {
                    guard cursor < bytes.count else { break }
                    byte = bytes[cursor]; cursor += 1
                    guard byte == 0xAA || byte == 0xA5 || (legacy && byte == 0x55) else { invalid = true; break }
                } else if byte == 0xAA { invalid = true; break }
                else if legacy && byte == 0x55 {
                    guard cursor < bytes.count else { break }
                    guard bytes[cursor] == 0x55 else { invalid = true; break }
                    consumed = cursor + 1; break
                }
                body.append(byte)
                if !legacy && body.count >= 2 {
                    guard [0x11,0x12,0x13,0x14,0x16].contains(body[0]), body[1] > 0 else { invalid = true; break }
                    if body.count == Int(body[1]) + 3 { consumed = cursor; break }
                }
                if body.count > 4096 { invalid = true; break }
            }
            if invalid { bytes.removeFirst(); continue }
            guard let consumed else { break }
            bytes.removeFirst(consumed)
            guard let checksum = body.last else { continue }
            let payload = Array(body.dropLast())
            if legacy {
                guard payload.reduce(0, &+) == checksum, payload.count >= 16,
                      payload[12] == 0xFE, WheelBytes.le32(payload,4) <= 4096,
                      payload.count == 16 + Int(WheelBytes.le32(payload,4)) else { continue }
                if let sample = decodeLegacy(id: WheelBytes.le32(payload,0), data: Array(payload.dropFirst(16)), at: date) { results.append(sample) }
            } else {
                guard payload.reduce(0, ^) == checksum else { continue }
                let extended = payload[0] == 0x16
                let position = extended ? 4 : 2
                guard payload.count > position else { continue }
                if extended { guard ([payload[2],payload[3]] == [2,0x21]) || ([payload[2],payload[3]] == [0x21,2]) else { continue } }
                if let sample = decodeModern(command: payload[position] & 0x7F, data: Array(payload.dropFirst(position+1)), at: date) { results.append(sample) }
            }
        }
        return results
    }
    private mutating func decodeLegacy(id: UInt32, data b: [UInt8], at date: Date) -> WheelTelemetry? {
        if id == 0x0F550114, b.count >= 108 {
            func digit(_ value: UInt8) -> Int? { if value >= 48 && value <= 57 { return Int(value-48) }; if value <= 9 { return Int(value) }; return nil }
            if let low = digit(b[104]), let high = digit(b[107]) { modelCode = high * 10 + low }
            // Codes >=100 use a two-digit high component on some firmwares.
            if b[107] >= 10 && b[107] <= 14 && b[104] <= 9 { modelCode = Int(b[107])*10 + Int(b[104]) }
            firmwareLabel = "\(b[27]).\(b[26]).\(WheelBytes.le16(b,24))"
            if [0,1].contains(b[80]) { lamp = (b[80] == 1,date) }
            diagnostic = modelCode.flatMap { Self.legacyModels[$0] } ?? "Неизвестная модель InMotion legacy; данные не интерпретируются."
            return nil
        }
        guard id == 0x0F550113, b.count >= 64, let modelCode, let name = Self.legacyModels[modelCode] else { return nil }
        let factor: Double = [1,5,30].contains(modelCode) ? 1000 : 3812
        let speed = (Double(WheelBytes.signed32(b,12)) + Double(WheelBytes.signed32(b,16))) / (2*factor) * 3.6
        let volts = Double(WheelBytes.le32(b,24))/100
        let amps = Double(WheelBytes.signed32(b,20))/1000
        guard WheelBytes.saneSpeed(speed), (10...260).contains(volts), abs(amps) <= 400 else { return nil }
        let knownMileage = (50...53).contains(modelCode) || [80,85,86,87,100,101,140,141,142,143].contains(modelCode)
        var sample = WheelTelemetry(receivedAt: date, speed: speed, pwm: nil, voltage: volts, temperature: [Double(b[32]),Double(b[34])].filter { (-40...150).contains($0) }.max(), firmware: 0, tripMeters: knownMileage ? WheelBytes.le32(b,48) : nil, totalMeters: knownMileage ? WheelBytes.le32(b,44) : nil, compatibleAlarm: false, alarm: nil, lightOn: WheelBytes.fresh(lamp,at: date,age: 10), phaseCurrent: nil, pitch: Double(WheelBytes.signed32(b,0))/65536, batteryReading: WheelBatteryReading(receivedAt: date,current: amps,power: volts*amps))
        sample.family = .inMotionV1; sample.model = name; sample.firmwareLabel = firmwareLabel; sample.integrity = .checksum
        if [80,85,86,87].contains(modelCode) { sample.reportedBattery = (volts-68)/14.5*100 }
        return sample
    }
    private mutating func decodeModern(command: UInt8, data b: [UInt8], at date: Date) -> WheelTelemetry? {
        if command == 2, dialect == .v6, b.count == 18, b[0] == 0x80, b[1] == 2 {
            // Echo only the wheel-provided challenge; no guessed password,
            // persisted secret, configuration write or auth for unknown models.
            pendingV6Echo = Self.modernQuery(command: 2,data: [0,0,0x82] + Array(b[2...17]),flags: 0x13)
            return nil
        }
        if command == 0x21, b.count >= 2, b[0] == 2 {
            return decodeRouted(command: b[1] & 0x7F, data: Array(b.dropFirst(2)), at: date)
        }
        // Extended envelopes normalized by the outer framer have already had
        // their routing pair removed; accept the same routed body once only.
        if command == 7, b.count >= 2, b[0] == 1, b[1] == 0 { return decodeP6(Array(b.dropFirst(2)), at: date) }
        if command == 4, dialect == .v6 { return decodeV6(b, at: date) }
        if command == 0x11, dialect == .v6 { updateV6Total(b, at: date); return nil }
        if command == 2, b.count >= 5, b[0] == 0x82, b[1] == 1 {
            selectModel(Int(b[3])*10 + Int(b[4])); return nil
        }
        if command == 2, b.count >= 4, b[0] == 1 {
            selectModel(Int(b[2])*10 + Int(b[3])); return nil
        }
        if command == 2, b.count >= 15, b[0] == 6 {
            firmwareLabel = "\(b[14]).\(b[13]).\(WheelBytes.le16(b,11))"; return nil
        }
        if command == 0x11, b.count >= 20 {
            let distance = UInt64(WheelBytes.le32(b,0))*10
            if distance <= UInt32.max { total = (UInt32(distance),date) }; return nil
        }
        guard command == 4, dialect == .standard, let modelCode, let name = Self.modernModels[modelCode] else { return nil }
        let v12 = [71,72,73].contains(modelCode)
        guard b.count >= (v12 ? 56 : 65) else { return nil }
        let volts = Double(WheelBytes.le16(b,0))/100
        let amps = Double(WheelBytes.signedLE(b,2))/100
        let speed = Double(WheelBytes.signedLE(b,v12 ? 4 : 8))/100
        let duty = abs(Double(WheelBytes.signedLE(b,v12 ? 8 : 14)))/100
        guard WheelBytes.saneSpeed(speed), (10...260).contains(volts), abs(amps) <= 400, duty <= 110 else { return nil }
        let temperatures = (v12 ? [40,41,43,44,45] : modelCode == 171 ? [58,59,61,63] : [58,59,60,61,62,63]).compactMap { i -> Double? in
            let temp = Double(b[i])-176
            return (-40...150).contains(temp) ? temp : nil
        }
        let trip = UInt32(WheelBytes.le16(b,v12 ? 22 : 28))*10
        let light: Bool? = v12 ? b[55] & 3 != 0 : b.count > 76 ? b[76] & 2 != 0 : nil
        var sample = WheelTelemetry(receivedAt: date,speed: speed,pwm: duty,voltage: volts,temperature: temperatures.max(),firmware: 0,tripMeters: trip,totalMeters: WheelBytes.fresh(total,at: date,age: 5),compatibleAlarm: false,alarm: nil,lightOn: light,phaseCurrent: nil,pitch: Double(WheelBytes.signedLE(b,v12 ? 16 : 20))/100,batteryReading: WheelBatteryReading(receivedAt: date,current: amps,power: volts*amps))
        sample.family = .inMotionV2; sample.model = name; sample.firmwareLabel = firmwareLabel; sample.integrity = .checksum; sample.batteryIsEstimated = false; sample.odometerQuantumMeters = 10
        let level = v12 ? Double(WheelBytes.le16(b,24))/100 : max(Double(WheelBytes.le16(b,34)),Double(WheelBytes.le16(b,36)))/100
        if (0...100).contains(level) { sample.reportedBattery = level }
        return sample
    }
    private mutating func selectModel(_ code: Int) {
        modelCode = code
        if code == 141 { dialect = .v6 }
        else if code == 21 { dialect = .p6 }
        else if Self.modernModels[code] != nil { dialect = .standard }
        else { dialect = .unresolved }
        diagnostic = Self.modernModels[code] ?? "Неизвестный carType InMotion; схема показаний не выбрана."
    }
    private mutating func decodeRouted(command: UInt8, data b: [UInt8], at date: Date) -> WheelTelemetry? {
        switch command {
        case 7:
            guard b.count >= 2, b[0] == 1, b[1] == 0 else { return nil }
            return decodeP6(Array(b.dropFirst(2)),at: date)
        case 4:
            guard dialect == .v6 else { return nil }
            return decodeV6(b,at: date)
        case 0x11:
            if dialect == .v6 { updateV6Total(b,at: date) }; return nil
        default: return nil
        }
    }
    private mutating func decodeP6(_ b: [UInt8], at date: Date) -> WheelTelemetry? {
        // High-confidence capture-backed fields agree in current primary
        // parser and protocol prose. Temperatures DON'T agree: keep nil.
        // body78 is TPMS in the corrected source, never an IMU temperature.
        guard b.count >= 62 else { return nil }
        let volts = Double(WheelBytes.le16(b,0))/100
        let amps = Double(WheelBytes.signedLE(b,2))/100
        let speed = Double(WheelBytes.signedLE(b,8))/100
        let duty = abs(Double(WheelBytes.signedLE(b,14)))/100
        let bank1 = Double(WheelBytes.le16(b,20))/100
        let bank2 = Double(WheelBytes.le16(b,22))/100
        let distance = UInt64(WheelBytes.le32(b,58))*10
        guard (100...260).contains(volts), abs(amps) <= 400, WheelBytes.saneSpeed(speed), duty <= 110,
              (0...100).contains(bank1), (0...100).contains(bank2), distance <= UInt32.max else { return nil }
        selectModel(21)
        var sample = WheelTelemetry(receivedAt: date,speed: speed,pwm: duty,voltage: volts,temperature: nil,firmware: 0,tripMeters: nil,totalMeters: UInt32(distance),compatibleAlarm: false,alarm: nil,lightOn: nil,
                                    batteryReading: WheelBatteryReading(receivedAt: date,current: amps,power: Double(WheelBytes.signedLE(b,16))))
        sample.family = .inMotionV2; sample.model = "InMotion P6"; sample.integrity = .checksum
        sample.reportedBattery = (bank1+bank2)/2; sample.batteryIsEstimated = false; sample.odometerQuantumMeters = 10
        return sample
    }
    private mutating func updateV6Total(_ b: [UInt8], at date: Date) {
        guard b.count >= 4 else { return }
        let distance = UInt64(WheelBytes.le32(b,0))*10
        if distance <= UInt32.max { total = (UInt32(distance),date) }
    }
    private func decodeV6(_ b: [UInt8], at date: Date) -> WheelTelemetry? {
        // V6 model141 must be confirmed by carType (including its0x13 wrapper)
        // BEFORE interpreting0x84, which means detailed temperatures on P6.
        guard dialect == .v6, b.count >= 56 else { return nil }
        let volts = Double(WheelBytes.le16(b,0))/100
        let amps = Double(WheelBytes.signedLE(b,2))/100
        let speed = Double(WheelBytes.signedLE(b,4))/100
        let duty = abs(Double(WheelBytes.signedLE(b,8)))/100
        guard (20...65).contains(volts), abs(amps) <= 400, WheelBytes.saneSpeed(speed), duty <= 110 else { return nil }
        var sample = WheelTelemetry(receivedAt: date,speed: speed,pwm: duty,voltage: volts,temperature: nil,firmware: 0,tripMeters: UInt32(WheelBytes.le16(b,22))*10,totalMeters: WheelBytes.fresh(total,at: date,age: 5),compatibleAlarm: false,alarm: nil,lightOn: nil,
                                    batteryReading: WheelBatteryReading(receivedAt: date,current: amps,power: volts*amps))
        sample.family = .inMotionV2; sample.model = "InMotion V6"; sample.integrity = .checksum
        sample.reportedBattery = (volts-44.4)*10; sample.batteryIsEstimated = true; sample.odometerQuantumMeters = 10
        return sample
    }

}
