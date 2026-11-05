import Foundation

struct WheelPhoneAlarmRule: Codable, Equatable {
    var enabled: Bool
    var threshold: Double
    var repeatInterval: Double
    func normalized(pwm: Bool) -> Self {
        Self(enabled: enabled,
             threshold: min(pwm ? 100 : 120, max(pwm ? 30 : 5, threshold.isFinite ? threshold : (pwm ? 80 : 35))),
             repeatInterval: min(30, max(1, repeatInterval.isFinite ? repeatInterval : 5)))
    }
}

struct WheelAlarmInputs {
    let speed: Double
    let pwm: Double?
    init?(sample: WheelTelemetry?, demo: Bool, at date: Date, percentage: Double) {
        guard !demo, let sample, sample.isFresh(at: date), sample.speed.isFinite, percentage.isFinite else { return nil }
        speed = abs(sample.speed) * percentage / 100
        pwm = sample.pwm
    }
}
struct WheelAlarmLatch {
    var active = false
    var lastSound = Date.distantPast
    mutating func evaluate(value: Double?, rule: WheelPhoneAlarmRule) {
        guard rule.enabled, let value, value.isFinite else { active = false; return }
        if value >= rule.threshold { active = true }
        else if value <= rule.threshold - 2 { active = false }
    }
}
