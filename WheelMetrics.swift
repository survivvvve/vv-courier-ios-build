import Foundation

enum WheelMetric: String, CaseIterable, Identifiable {
    case speed, pwm, charge, voltage, temperature, phaseCurrent, batteryCurrent, batteryPower, pitch, trip, odometer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speed: return "Скорость"
        case .pwm: return "ШИМ"
        case .charge: return "Заряд"
        case .voltage: return "Напряжение"
        case .temperature: return "Контроллер"
        case .phaseCurrent: return "Фазный ток"
        case .batteryCurrent: return "Ток батареи"
        case .batteryPower: return "Мощность батареи"
        case .pitch: return "Наклон"
        case .trip: return "Пробег поездки"
        case .odometer: return "Общий пробег"
        }
    }
    var unit: String {
        switch self {
        case .speed: return "км/ч"
        case .pwm, .charge: return "%"
        case .voltage: return "В"
        case .temperature: return "°C"
        case .phaseCurrent, .batteryCurrent: return "А"
        case .batteryPower: return "Вт"
        case .pitch: return "°"
        case .trip, .odometer: return "км"
        }
    }
    var note: String? {
        switch self {
        case .charge: return "Процент от колеса, если он передаётся; иначе оценка по напряжению для опознанной модели."
        case .phaseCurrent: return "Ток двигателя; отличается от тока батареи."
        case .batteryCurrent, .batteryPower: return "По данным батареи, если колесо их передаёт. Мощность = напряжение × ток батареи."
        case .pitch: return "Продольный угол, который сообщает колесо."
        default: return nil
        }
    }
    func value(sample: WheelTelemetry?, battery: WheelBatteryReading?, fresh: Bool, at date: Date, demo: Bool, speedPercentage: Double = 100) -> String {
        guard fresh, let sample else { return "—" }
        switch self {
        case .speed: return String(format: "%.1f", abs(sample.speed) * speedPercentage / 100)
        case .pwm: return sample.pwm.map { String(format: "%.1f", $0) } ?? "—"
        case .charge: return sample.estimatedBattery.map(String.init) ?? "—"
        case .voltage: return sample.voltage.map { String(format: "%.1f", $0) } ?? "—"
        case .temperature: return sample.temperature.map { String(format: "%.0f", $0) } ?? "—"
        case .phaseCurrent: return sample.phaseCurrent.map { String(format: "%.1f", $0) } ?? "—"
        case .batteryCurrent: return battery.flatMap { demo || $0.isFresh(at: date) ? String(format: "%.1f", $0.current) : nil } ?? "—"
        case .batteryPower: return battery.flatMap { demo || $0.isFresh(at: date) ? ($0.power.map { String(format: "%.0f", $0) } ?? "—") : nil } ?? "—"
        case .pitch: return sample.pitch.map { String(format: "%.1f", $0) } ?? "—"
        case .trip: return sample.tripMeters.map { String(format: "%.2f", Double($0) / 1000) } ?? "—"
        case .odometer: return sample.totalMeters.map { String(format: "%.1f", Double($0) / 1000) } ?? "—"
        }
    }
}

