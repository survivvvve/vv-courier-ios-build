import Foundation
import Combine

struct WheelRideSummary {
    let meters: Double
    let movingSeconds: Double
    let averageSpeed: Double?
    let maxSpeed: Double?
    let maxPWM: Double?
    let maxTemperature: Double?
    let hasData: Bool
    let daysWithData: Int
    let hasGaps: Bool
    let observedSeconds: Double
    let firstRecorded: Date?
    let lastRecorded: Date?
}

// Single main-thread writer. Each installation owner + authenticated courier +
// BLE UUID + Moscow day has its own bucket. Never infer missing travel from an
// odometer difference across a reconnect, process restart or unknown shift.
final class WheelRideStore: ObservableObject {
    static let shared = WheelRideStore()
    @Published private(set) var revision = 0
    @Published private(set) var storageError: String?
    @Published private(set) var currentCourierID: String?
    @Published private(set) var recordingAllowed = false
    private struct Bucket: Codable {
        var courierID: String
        var wheelID: String
        var day: String
        var meters = 0.0
        var movingSeconds = 0.0
        var speedSeconds = 0.0
        var observedSeconds = 0.0
        var maxSpeed: Double?
        var maxPWM: Double?
        var maxTemperature: Double?
        var firstRecorded: Date
        var lastRecorded: Date
        // A recording cannot prove full VV shift coverage from wheel frames.
        // Starting mid-shift, missing BLE or restarting leaves a partial record.
        var hasGaps = true
    }
    private struct Archive: Codable { let version: Int; let owner: String; let buckets: [Bucket] }
    private struct Baseline {
        let courier: String
        let wheel: String
        let day: String
        let sample: WheelTelemetry
        let speed: Double
        let uptime: TimeInterval
    }
    private var buckets: [Bucket] = []
    private var baseline: Baseline?
    private var contextKnown = false
    private var contextActive = false
    private var contextDemo = false
    private var dirty = false
    private var archiveBlocked = false
    private var checkpoint: DispatchWorkItem?
    private var revisionWork: DispatchWorkItem?
    private var revisionGeneration = 0
    private var lastRevisionUptime = -Double.infinity
    private let speedPreferences: WheelSpeedPreferences
    private let owner: String
    private let file: URL?
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }
    static func dayKey(at date: Date = Date()) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", values.year ?? 0, values.month ?? 0, values.day ?? 0)
    }
    init(directory: URL? = nil, defaults: UserDefaults = .standard, speedPreferences: WheelSpeedPreferences = .shared) {
        self.speedPreferences = speedPreferences
        let ownerKey = "wheel.rides.installation.owner.v1"
        let owner = defaults.string(forKey: ownerKey) ?? UUID().uuidString
        self.owner = owner
        defaults.set(owner, forKey: ownerKey)
        let base = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("VVCourier", isDirectory: true))
        if let directory = base {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                file = directory.appendingPathComponent("wheel-rides-v1.json")
            } catch { file = nil; storageError = "Не удалось открыть локальное хранилище поездок." }
        } else { file = nil; storageError = "Локальное хранилище поездок недоступно." }
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.version == 1, archive.owner == owner else { archiveBlocked = true; storageError = "Архив поездок принадлежит другой установке или версии приложения."; return }
                buckets = archive.buckets.filter(Self.valid)
            } catch { archiveBlocked = true; storageError = "Не удалось прочитать сохранённые итоги езды. Новые данные не заменят этот файл." }
        }
    }
    private static func valid(_ bucket: Bucket) -> Bool {
        !bucket.courierID.isEmpty && UUID(uuidString: bucket.wheelID) != nil && bucket.day == dayKey(at: bucket.firstRecorded)
        && bucket.meters.isFinite && bucket.meters >= 0 && bucket.movingSeconds.isFinite && bucket.movingSeconds >= 0
        && bucket.speedSeconds.isFinite && bucket.speedSeconds >= 0 && bucket.observedSeconds.isFinite && bucket.observedSeconds >= bucket.movingSeconds
        && [bucket.maxSpeed, bucket.maxPWM, bucket.maxTemperature].compactMap { $0 }.allSatisfy { $0.isFinite }
    }
    func setContext(courierID: String?, active: Bool, known: Bool, demo: Bool) {
        precondition(Thread.isMainThread)
        let courier = courierID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = courier?.isEmpty == false ? courier : nil
        let changed = currentCourierID != normalized || contextActive != active || contextKnown != known || contextDemo != demo
        guard changed else { return }
        // Flush under the OLD owner/courier before changing identity. Baselines
        // never cross an account, demo or VV shift-state boundary.
        flush(); baseline = nil
        currentCourierID = normalized; contextActive = active; contextKnown = known; contextDemo = demo
        recordingAllowed = normalized != nil && active && known && !demo
        publishRevision()
    }
    func receive(_ sample: WheelTelemetry, wheelID: String) {
        precondition(Thread.isMainThread)
        guard recordingAllowed, let courier = currentCourierID,
              UUID(uuidString: wheelID) != nil, sample.isFresh(), sample.speed.isFinite,
              sample.pwm?.isFinite != false, sample.temperature?.isFinite != false else { baseline = nil; return }
        let date = sample.receivedAt
        let day = Self.dayKey(at: date)
        let uptime = ProcessInfo.processInfo.systemUptime
        let corrected = abs(speedPreferences.corrected(sample.speed, wheelID: wheelID))
        let next = Baseline(courier: courier, wheel: wheelID, day: day, sample: sample, speed: corrected, uptime: uptime)
        defer { baseline = next }
        let index: Int
        if let existing = buckets.firstIndex(where: { $0.courierID == courier && $0.wheelID == wheelID && $0.day == day }) { index = existing }
        else {
            buckets.append(Bucket(courierID: courier, wheelID: wheelID, day: day, firstRecorded: date, lastRecorded: date))
            index = buckets.count - 1
        }
        // Maxima are observed values, including the first valid sample; they
        // never imply a reconstructed route or full-day coverage.
        buckets[index].maxSpeed = max(buckets[index].maxSpeed ?? corrected, corrected)
        if let value = sample.pwm { buckets[index].maxPWM = max(buckets[index].maxPWM ?? value, value) }
        if let value = sample.temperature { buckets[index].maxTemperature = max(buckets[index].maxTemperature ?? value, value) }
        buckets[index].lastRecorded = max(buckets[index].lastRecorded, date)
        defer { changed() }
        guard let previous = baseline, previous.courier == courier, previous.wheel == wheelID, previous.day == day else { return }
        let elapsed = date.timeIntervalSince(previous.sample.receivedAt)
        let monotonicElapsed = uptime - previous.uptime
        // Frames received together may share a timestamp. They contribute no
        // duplicate distance or time. Clock changes and >3s gaps reset baseline.
        guard elapsed > 0 else { return }
        guard elapsed <= 3, monotonicElapsed >= 0, abs(elapsed - monotonicElapsed) <= 1 else { buckets[index].hasGaps = true; return }
        let before = previous.sample.totalMeters
        let after = sample.totalMeters
        if let before, let after {
            guard after >= before else { buckets[index].hasGaps = true; return }
            let distance = Double(after - before)
            let endpointSpeed = max(abs(previous.sample.speed), abs(sample.speed))
            let quantum = min(10,max(1,previous.sample.odometerQuantumMeters,sample.odometerQuantumMeters))
            let allowance = 2 * quantum + 1
            let plausible = min(200 / 3.6 * elapsed + allowance, (endpointSpeed + 10) / 3.6 * elapsed + allowance)
            guard distance <= plausible else { buckets[index].hasGaps = true; return }
            buckets[index].meters += distance
        } else {
            // No lifetime odometer? Still record observed moving time/speeds,
            // but never manufacture kilometres by integrating speed.
            buckets[index].hasGaps = true
        }
        buckets[index].observedSeconds += elapsed
        // Movement uses raw wheel speed (>=1 km/h), not an edited multiplier.
        // The averaged values use the correction in effect at EACH endpoint;
        // persisted intervals are never reprocessed when calibration changes.
        if (abs(previous.sample.speed) + abs(sample.speed)) / 2 >= 1 {
            buckets[index].movingSeconds += elapsed
            buckets[index].speedSeconds += (previous.speed + corrected) / 2 * elapsed
        }
    }
    func disconnected() {
        precondition(Thread.isMainThread)
        baseline = nil
        flush()
    }
    private func changed() {
        dirty = true
        scheduleRevision()
        guard checkpoint == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.checkpoint = nil; self?.flush() }
        checkpoint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }
    private func scheduleRevision() {
        guard revisionWork == nil else { return }
        let delay = 1 - (ProcessInfo.processInfo.systemUptime - lastRevisionUptime)
        guard delay > 0 else { publishRevision(); return }
        let generation = revisionGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revisionGeneration == generation else { return }
            self.revisionWork = nil
            self.scheduleRevision()
        }
        revisionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func publishRevision() {
        // Context transitions notify immediately and invalidate any old pending
        // UI update. Telemetry is still aggregated and persisted at full rate.
        revisionWork?.cancel(); revisionWork = nil; revisionGeneration &+= 1
        lastRevisionUptime = ProcessInfo.processInfo.systemUptime
        revision += 1
    }
    func flush() {
        precondition(Thread.isMainThread)
        checkpoint?.cancel(); checkpoint = nil
        guard dirty, let file else { return }
        // A corrupt/unrecognized existing archive is never silently overwritten.
        guard !archiveBlocked else { return }
        do {
            let data = try JSONEncoder().encode(Archive(version: 1, owner: owner, buckets: buckets))
            #if os(iOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            dirty = false; storageError = nil
        } catch { storageError = "Не удалось сохранить итоги езды на iPhone: " + error.localizedDescription }
    }
    func summary(courierID: String, days: [String]) -> WheelRideSummary {
        precondition(Thread.isMainThread)
        let wanted = Set(days)
        let selected = buckets.filter { $0.courierID == courierID && wanted.contains($0.day) }
        let moving = selected.reduce(0) { $0 + $1.movingSeconds }
        let speedSeconds = selected.reduce(0) { $0 + $1.speedSeconds }
        return WheelRideSummary(meters: selected.reduce(0) { $0 + $1.meters }, movingSeconds: moving,
                                averageSpeed: moving > 0 ? speedSeconds / moving : nil,
                                maxSpeed: selected.compactMap(\.maxSpeed).max(), maxPWM: selected.compactMap(\.maxPWM).max(),
                                maxTemperature: selected.compactMap(\.maxTemperature).max(), hasData: !selected.isEmpty,
                                daysWithData: Set(selected.map(\.day)).count, hasGaps: selected.contains(where: \.hasGaps),
                                observedSeconds: selected.reduce(0) { $0 + $1.observedSeconds },
                                firstRecorded: selected.map(\.firstRecorded).min(), lastRecorded: selected.map(\.lastRecorded).max())
    }
    var today: WheelRideSummary? {
        guard let currentCourierID else { return nil }
        return summary(courierID: currentCourierID, days: [Self.dayKey()])
    }
}
