import Foundation

struct TelegramOrderRecord: Codable, Equatable {
    let id: String
    let label: String
    let shopID: Int?
    let weight: Double?
    let reward: Double?
    let express: Bool
    init(id: String, label: String, shopID: Int? = nil, weight: Double? = nil, reward: Double? = nil, express: Bool) {
        self.id = id; self.label = label; self.shopID = shopID; self.weight = weight; self.reward = reward; self.express = express
    }
}

struct TelegramOrderEvent: Codable, Equatable, Identifiable {
    let epoch: String
    let courierID: String
    let parcel: TelegramOrderRecord
    let kind: ExpressEventKind
    let observedAt: Date
    var id: String { "vv.telegram.\(epoch).\(kind.rawValue).\(parcel.id)" }
    var messageText: String {
        let labelDigits = parcel.label.filter { $0.isNumber }
        let number = String((labelDigits.isEmpty ? parcel.id.filter { $0.isNumber } : labelDigits).suffix(5))
        let title = parcel.express ? "⚡ " + kind.title : kind == .created ? "Новый заказ" : "Заказ готов"
        var lines = [title, "Заказ " + (number.isEmpty ? "—" : number) + (parcel.shopID.flatMap { $0 > 0 ? " · магазин \($0)" : nil } ?? "")]
        var metrics: [String] = []
        if let value = parcel.weight, value.isFinite, value >= 0, let text = Self.weightFormatter.string(from: NSNumber(value: value)) { metrics.append("Вес " + text + " кг") }
        if let value = parcel.reward, value.isFinite, value >= 0, let text = Self.rewardFormatter.string(from: NSNumber(value: value)) { metrics.append(text + " ₽") }
        if !metrics.isEmpty { lines.append(metrics.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }
    private static let weightFormatter = formatter(minimum: 0, maximum: 3)
    private static let rewardFormatter = formatter(minimum: 2, maximum: 2)
    private static func formatter(minimum: Int, maximum: Int) -> NumberFormatter {
        let result = NumberFormatter(); result.locale = Locale(identifier: "ru_RU"); result.numberStyle = .decimal
        result.minimumFractionDigits = minimum; result.maximumFractionDigits = maximum; result.usesGroupingSeparator = false
        return result
    }
}

/// A separate channel keeps Telegram deduplication independent of the local
/// iPhone banners. Detection still uses the same proven shift/feed transitions.
struct TelegramOrderLedger: Codable {
    private var ledger = ExpressNotificationLedger()
    private var onlyExpressMode: Bool?
    var active: Bool { ledger.active }
    var epoch: String { ledger.epoch }
    var lastObservedAt: Date? { ledger.lastObservedAt }

    mutating func endShift() { ledger.endShift(); onlyExpressMode = nil }

    mutating func observe(courierID: String, shops: [Int], shiftActive: Bool?, assembling: [TelegramOrderRecord], ready: [TelegramOrderRecord], onlyExpress: Bool, suppressExisting: Bool = false, at date: Date = Date()) -> [TelegramOrderEvent] {
        guard !courierID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { endShift(); return [] }
        guard shiftActive != nil else { return [] }
        let modeChanged = onlyExpressMode.map { $0 != onlyExpress } ?? false
        onlyExpressMode = onlyExpress
        let assembling = assembling.filter { !onlyExpress || $0.express }
        let ready = ready.filter { !onlyExpress || $0.express }
        let quiet = suppressExisting || modeChanged || ExpressNotificationDelivery.needsQuietResume(lastObservedAt: ledger.lastObservedAt, at: date)
        let events = ledger.observe(courierID: courierID, shops: shops, shiftActive: shiftActive,
                                    assembling: assembling.map { ExpressParcelReference(id: $0.id, label: $0.label, shopID: $0.shopID) },
                                    ready: ready.map { ExpressParcelReference(id: $0.id, label: $0.label, shopID: $0.shopID) }, suppressExisting: quiet, at: date)
        var records: [String: TelegramOrderRecord] = [:]
        for parcel in assembling where records[parcel.id] == nil { records[parcel.id] = parcel }
        for parcel in ready { records[parcel.id] = parcel }
        return events.compactMap { event in
            records[event.parcel.id].map { TelegramOrderEvent(epoch: event.epoch, courierID: event.courierID, parcel: $0, kind: event.kind, observedAt: event.observedAt) }
        }
    }
}
