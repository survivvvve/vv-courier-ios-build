import Foundation
import Combine

// A display/phone-alert calibration only. Raw frames, wheel counters, write
// guards and wheel-side limits never use this factor. One value per BLE UUID.
final class WheelSpeedPreferences: ObservableObject {
    static let shared = WheelSpeedPreferences()
    @Published private(set) var wheelID: String?
    @Published private(set) var wheelName: String
    @Published private(set) var percentage: Double = 100
    private let defaults: UserDefaults
    private let key = "wheel.speed.correction.v1"
    private var factors: [String: Double]
    private var names: [String: String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        factors = (defaults.dictionary(forKey: "wheel.speed.correction.v1") ?? [:]).reduce(into: [:]) { result, pair in
            if let value = pair.value as? Double, value.isFinite, (50...150).contains(value) { result[pair.key] = value }
        }
        names = defaults.dictionary(forKey: "wheel.speed.names.v1") as? [String: String] ?? [:]
        wheelID = defaults.string(forKey: "wheel.sherman.peripheral")
        wheelName = "Колесо"
        if let wheelID { wheelName = names[wheelID] ?? "Колесо"; percentage = factors[wheelID] ?? 100 }
    }
    func selectWheel(id: String?, name: String? = nil) {
        guard let id, UUID(uuidString: id) != nil else { return }
        if let name, !name.isEmpty { names[id] = name; defaults.set(names, forKey: "wheel.speed.names.v1") }
        wheelID = id; wheelName = names[id] ?? "Колесо"; percentage = factors[id] ?? 100
    }
    @discardableResult func setPercentage(_ value: Double) -> Bool {
        guard let wheelID, value.isFinite, (50...150).contains(value) else { return false }
        let rounded = (value * 10).rounded() / 10
        factors[wheelID] = rounded; percentage = rounded
        defaults.set(factors, forKey: key)
        return true
    }
    func corrected(_ raw: Double) -> Double { raw * percentage / 100 }
    func corrected(_ raw: Double, wheelID: String) -> Double { raw * (factors[wheelID] ?? 100) / 100 }
}
