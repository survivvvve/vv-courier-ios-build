import Foundation
import Combine

final class WheelDashboardPreferences: ObservableObject {
    static let shared = WheelDashboardPreferences()
    static let defaults: [WheelMetric] = [.speed, .pwm, .charge, .voltage, .temperature, .trip]
    private let defaults: UserDefaults
    private let key = "wheel.dashboard.metrics.v1"
    @Published private(set) var metrics: [WheelMetric]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: "wheel.dashboard.metrics.v1")
        var seen = Set<WheelMetric>()
        let valid = (stored ?? []).compactMap(WheelMetric.init(rawValue:)).filter { seen.insert($0).inserted }
        metrics = valid.isEmpty ? Self.defaults : valid
    }
    func add(_ metric: WheelMetric) { guard !metrics.contains(metric) else { return }; metrics.append(metric); save() }
    func remove(_ metric: WheelMetric) { guard metrics.count > 1 else { return }; metrics.removeAll { $0 == metric }; save() }
    func move(from source: IndexSet, to destination: Int) {
        let valid = source.filter { metrics.indices.contains($0) }
        let values = valid.map { metrics[$0] }
        let target = destination - valid.filter { $0 < destination }.count
        for index in valid.reversed() { metrics.remove(at: index) }
        metrics.insert(contentsOf: values, at: max(0,min(metrics.count,target))); save()
    }
    func restore() { metrics = Self.defaults; save() }
    private func save() { defaults.set(metrics.map(\.rawValue), forKey: key) }
}

