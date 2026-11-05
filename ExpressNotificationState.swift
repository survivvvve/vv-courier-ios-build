import Foundation

enum ExpressEventKind: String, Codable, CaseIterable {
    case created, ready
    var title: String { self == .created ? "Оформлен экспресс" : "Экспресс готов" }
}

struct ExpressParcelReference: Codable, Equatable {
    let id: String
    let label: String
    let shopID: Int?
}

struct ExpressOrderEvent: Codable, Equatable, Identifiable {
    let epoch: String
    let courierID: String
    let parcel: ExpressParcelReference
    let kind: ExpressEventKind
    let observedAt: Date
    var id: String { "vv.express.\(epoch).\(kind.rawValue).\(parcel.id)" }
}

struct ExpressNotificationTarget: Identifiable, Equatable {
    let id = UUID()
    let courierID: String
    let parcelID: String
    let kind: ExpressEventKind
}

/// Pure transition detector. A missing assembly row is never evidence of
/// readiness. Both snapshots must have completed before calling this method.
struct ExpressNotificationLedger: Codable {
    private struct Seen: Codable {
        var assembling: Bool
        var ready: Bool
        var lastSeen: Date
    }
    private(set) var scope = ""
    private(set) var epoch = UUID().uuidString
    private(set) var active = false
    private(set) var lastObservedAt: Date?
    private var baseline = false
    private var seen: [String: Seen] = [:]

    mutating func endShift() {
        active = false; baseline = false; seen = [:]; lastObservedAt = nil; epoch = UUID().uuidString
    }

    mutating func observe(courierID: String, shops: [Int], shiftActive: Bool?, assembling: [ExpressParcelReference], ready: [ExpressParcelReference], suppressExisting: Bool = false, at date: Date = Date()) -> [ExpressOrderEvent] {
        guard let shiftActive else { return [] }
        guard shiftActive else { if active { endShift() }; return [] }
        let nextScope = courierID + ":" + Set(shops).sorted().map(String.init).joined(separator: ",")
        if scope != nextScope || !active {
            scope = nextScope; active = true; baseline = false; seen = [:]; epoch = UUID().uuidString
        }
        let quiet = !baseline || suppressExisting
        var result: [ExpressOrderEvent] = []
        let readyIDs = Set(ready.map(\.id))
        for parcel in assembling where !parcel.id.isEmpty {
            var state = seen[parcel.id] ?? Seen(assembling: false, ready: false, lastSeen: date)
            if !quiet && !state.assembling && !state.ready && !readyIDs.contains(parcel.id) {
                result.append(ExpressOrderEvent(epoch: epoch, courierID: courierID, parcel: parcel, kind: .created, observedAt: date))
            }
            state.assembling = true; state.lastSeen = date; seen[parcel.id] = state
        }
        for parcel in ready where !parcel.id.isEmpty {
            var state = seen[parcel.id] ?? Seen(assembling: false, ready: false, lastSeen: date)
            if !quiet && !state.ready {
                result.append(ExpressOrderEvent(epoch: epoch, courierID: courierID, parcel: parcel, kind: .ready, observedAt: date))
            }
            state.ready = true; state.lastSeen = date; seen[parcel.id] = state
        }
        baseline = true
        lastObservedAt = date
        if seen.count > 4000 {
            let currentIDs = Set(assembling.map(\.id)).union(readyIDs)
            let retained = seen.filter { currentIDs.contains($0.key) }
            let recent = seen.filter { !currentIDs.contains($0.key) }.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(3000)
            seen = retained.merging(Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })) { old, _ in old }
        }
        return result
    }
}

/// Shared by delivery and the foreground UI. A cached active flag is not a
/// confirmation: only a successful server check can refresh confirmedAt.
enum ExpressNotificationDelivery {
    static func isCurrent(courierID: String, expectedCourierID: String?, epoch: String, expectedEpoch: String,
                          active: Bool, confirmedAt: Date, observedAt: Date, at date: Date = Date()) -> Bool {
        let confirmationAge = date.timeIntervalSince(confirmedAt)
        let eventAge = date.timeIntervalSince(observedAt)
        return !courierID.isEmpty && courierID == expectedCourierID && epoch == expectedEpoch && active
            && confirmationAge >= 0 && confirmationAge <= 30 && eventAge >= 0 && eventAge < 120
    }
    static func needsQuietResume(lastObservedAt: Date?, at date: Date = Date()) -> Bool {
        guard let lastObservedAt else { return true }
        let age = date.timeIntervalSince(lastObservedAt)
        return age < 0 || age > 120
    }
}

/// Foreground notices have the same identity and inventory rules as system
/// notifications. A ready event replaces its assembly notice, never doubles it.
struct ExpressForegroundInbox {
    private(set) var events: [ExpressOrderEvent] = []
    mutating func reset() { events = [] }
    mutating func dismiss(_ id: String) { events.removeAll { $0.id == id } }
    mutating func update(_ incoming: [ExpressOrderEvent], courierID: String, epoch: String,
                         assembling: Set<String>, ready: Set<String>, allowedKinds: Set<ExpressEventKind>, at date: Date = Date()) {
        let existing = Set(events.map(\.id))
        events.append(contentsOf: incoming.filter { !existing.contains($0.id) })
        var retained = Set<String>()
        events = events.filter { event in
            guard event.courierID == courierID, event.epoch == epoch, allowedKinds.contains(event.kind),
                  date.timeIntervalSince(event.observedAt) >= 0, date.timeIntervalSince(event.observedAt) < 120,
                  retained.insert(event.id).inserted else { return false }
            return event.kind == .ready ? ready.contains(event.parcel.id) : assembling.contains(event.parcel.id) && !ready.contains(event.parcel.id)
        }
        events = Array(events.suffix(20))
    }
}

#if DEBUG
/// A UI fixture only: these exact launch flags and the nonpersistent fake
/// session are required. This type and its route are absent from Release.
enum ExpressNotificationUIPreview {
    static let parcelID = "22421"
    static let epoch = "offline-ui-preview"
    static func enabled(demo: Bool, courierID: String?, token: String?, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        demo && courierID == "demo" && token == "offline-fixture-token"
            && arguments.contains("--ui-testing") && arguments.contains("--original-express-preview")
    }
    static func event(at date: Date = Date()) -> ExpressOrderEvent {
        ExpressOrderEvent(epoch: epoch, courierID: "demo", parcel: ExpressParcelReference(id: parcelID, label: "ДЕМО · 22421", shopID: 5470), kind: .ready, observedAt: date)
    }
}
#endif
