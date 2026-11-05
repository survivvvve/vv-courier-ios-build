import Foundation
import CoreFoundation

struct Session: Codable {
    let token: String
    let courierID: String
}

struct CourierError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var businessCode: Int? = nil
    var errorDescription: String? { message }
}

struct Shop: Identifiable, Codable, Hashable {
    let id: Int
    let address: String
    let name: String
    let active: Bool
    let color: String?
    let latitude: Double?
    let longitude: Double?
    var title: String { name.isEmpty ? "Магазин №\(id)" : name }
    init(id: Int, address: String, name: String = "", active: Bool = false, color: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id; self.address = address; self.name = name; self.active = active; self.color = color
        self.latitude = latitude; self.longitude = longitude
    }
    init?(_ raw: [String: Any]) {
        guard let id = Int(firstAddressText(raw["shopno"], raw["shop_number"])), id > 0 else { return nil }
        self.id = id
        address = firstAddressText(raw["address"], raw["Adress"], raw["shop_address"], raw["user_address"])
        name = firstAddressText(raw["name"], raw["shop_name"])
        active = truth(raw["shop_active"])
        let mapColor = firstAddressText(raw["color"], raw["colour_tt"])
        color = mapColor.isEmpty ? nil : mapColor
        latitude = Double(firstAddressText(raw["latitude"], raw["latitude_tt"], raw["shop_lat"], raw["lat"]).replacingOccurrences(of: ",", with: "."))
        longitude = Double(firstAddressText(raw["longitude"], raw["longitude_tt"], raw["shop_lon"], raw["lon"], raw["lng"]).replacingOccurrences(of: ",", with: "."))
    }
}

struct ParcelFeed {
    var parcels: [Parcel]
    var checking: [String: Any]
    var total: Int
    var mapShops: [[String: Any]] = []
    func inspectionMode(_ parcel: Parcel, after: Bool) -> Int {
        if after {
            let rules = checking["parcels_packages_inspection_after"] as? [String: Any] ?? [:]
            return integer(rules[parcel.id]) ?? 0
        }
        return integer(checking["all_packages_inspection_before"]) ?? 0
    }
}

enum Feed: String, CaseIterable, Identifiable {
    case available, assembly, mine
    var id: String { rawValue }
    var title: String {
        switch self { case .available: return "Доступные"; case .assembly: return "Сборка"; case .mine: return "Мои" }
    }
    var endpoint: String {
        switch self {
        case .available: return "get_parcels_assembled_ext"
        case .assembly: return "get_parcels_assembling_ext"
        case .mine: return "get_parcels_assigned_to_me_ext"
        }
    }
}

func number(_ value: Any?) -> Double {
    finiteNumber(value) ?? 0
}

func finiteNumber(_ value: Any?) -> Double? {
    if let value = value as? [String: Any] { return finiteNumber(value["profit"] ?? value["sum"]) }
    if let numeric = value as? NSNumber, CFGetTypeID(numeric) == CFBooleanGetTypeID() { return nil }
    let parsed = Double(string(value).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: "\u{202f}", with: "").replacingOccurrences(of: ",", with: "."))
    return parsed?.isFinite == true ? parsed : nil
}

/// Server counters and enums must be integral and representable. Never convert
/// an untrusted Double directly to Int (NaN, infinity and overflow trap).
func integer(_ value: Any?) -> Int? {
    if let numeric = value as? NSNumber, CFGetTypeID(numeric) == CFBooleanGetTypeID() { return nil }
    let text = string(value).trimmingCharacters(in: .whitespacesAndNewlines)
    if let exact = Int(text) { return exact }
    guard let number = Double(text), number.isFinite, number.rounded(.towardZero) == number,
          number > Double(Int.min), number < Double(Int.max) else { return nil }
    return Int(number)
}

/// Shared page accounting for feeds and archives. Category dictionaries are not
/// scalar totals. A short page cannot terminate a known larger result, and a
/// repeated page must never become a supposedly complete income report.
struct CourierPagination {
    let limit: Int
    let maximum: Int
    private(set) var offset = 0
    private(set) var total: Int?
    private(set) var seen = Set<String>()
    init(limit: Int, maximum: Int = 10_000) { self.limit = limit; self.maximum = maximum }
    mutating func consume(_ rows: [[String: Any]], reportedTotal: Any?, idKeys: [String] = ["id_parcel"]) throws -> (rows: [[String: Any]], complete: Bool) {
        if let raw = reportedTotal, !(raw is NSNull), !(raw is [String: Any]) {
            guard let count = integer(raw), count >= 0 else { throw CourierError(message: "ВВ вернул некорректное количество заказов. Обнови список.") }
            total = max(total ?? 0, count)
        }
        var fresh: [[String: Any]] = []
        for row in rows {
            let id = idKeys.lazy.map { string(row[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            guard !id.isEmpty else { throw CourierError(message: "ВВ не сообщил номер одного из заказов. Список не загружен полностью.") }
            if seen.insert(id).inserted { fresh.append(row) }
        }
        if !rows.isEmpty && fresh.isEmpty { throw CourierError(message: "ВВ повторяет страницу заказов. Неполный список не сохранён.") }
        offset += rows.count
        guard offset <= maximum else { throw CourierError(message: "Список ВВ слишком большой для полной загрузки. Выбери один магазин или меньший период.") }
        if let total {
            guard seen.count <= total else { throw CourierError(message: "Количество заказов ВВ изменилось во время загрузки. Обнови список целиком.") }
            if seen.count >= total { return (fresh, true) }
            guard !rows.isEmpty else { throw CourierError(message: "Архив или список ВВ загрузился не полностью. Повтори обновление позже.") }
        } else if rows.count < limit { return (fresh, true) }
        guard offset < maximum else { throw CourierError(message: "Список ВВ слишком большой для полной загрузки. Выбери один магазин или меньший период.") }
        return (fresh, false)
    }
}

func string(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    return String(describing: value)
}

func timestamp(_ value: Any?) -> Date? {
    let raw = string(value)
    guard raw.count >= 10, let year = Int(raw.prefix(4)), year >= 2000 else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: raw) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: raw) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) { return date }
    }
    return nil
}

struct Parcel: Identifiable {
    var raw: [String: Any]
    let id: String
    let label: String
    let fullNumber: String
    let streetLine: String
    let detailsLine: String
    let address: String
    let weight: Double
    let reward: Double
    let deadline: Date?
    let assemblyStarted: Date?
    let buyerComments: [String]
    let courierComments: [String]
    var status: String
    let express: Bool
    let water: Bool
    let eggs: Bool
    let shopID: Int?
    let doorphone: String
    let deliverySlot: String
    var statusTitle: String {
        if status == "created" { return assemblyStarted == nil ? "Ожидает сборки" : "Собирается" }
        return ["pickuped": "Взят", "on_the_way": "В пути", "arrived": "На месте", "on_return": "Возвращается", "returned": "Возвращён", "delivered": "Доставлен", "assembled": "Готов", "assembling": "Собирается", "awaiting_return": "Ожидает возврата", "awaiting_deletion": "Отменяется"][status] ?? (status.isEmpty ? "Заказ" : status)
    }

    init(_ raw: [String: Any]) {
        self.raw = raw
        id = string(raw["id_parcel"])
        fullNumber = firstAddressText(raw["id_general_view"], raw["id_parcel"])
        label = String(fullNumber.suffix(5))
        weight = number(raw["weight"])
        reward = number(raw["reward"] ?? raw["courier_profit_sum"])
        // The courier deadline drives available/normal order timers. Customer
        // delivery-slot bounds remain separate below and must not replace it.
        deadline = ["task_date_supply_until_courier_rfc", "task_date_supply_untill", "date_supply_until_rfc", "date_supply_untill"]
            .compactMap { timestamp(raw[$0]) }.first
        assemblyStarted = ["date_collect_start_rfc", "date_collect_start"].compactMap { timestamp(raw[$0]) }.first
        status = string(raw["parcel_status"] ?? raw["delivery_status"])
        express = ["1", "true"].contains(string(raw["fast_delivery"]).lowercased())
        func category(_ value: Any) -> String {
            if let rows = value as? [Any] { return rows.map(category).joined(separator: " ") }
            if let row = value as? [String: Any] {
                return row.filter { ["pp_id", "text", "tooltip", "code", "icon", "cdn_link", "name"].contains($0.key) }.values.map(category).joined(separator: " ")
            }
            return string(value).lowercased()
        }
        let metadata = ["properties", "properties_v2", "properties_images"].compactMap { raw[$0] }.map(category).joined(separator: " ")
        water = metadata.contains("вода") || metadata.contains("water") || metadata.split(separator: " ").contains("761")
        eggs = metadata.contains("яйц") || metadata.contains("egg")
        shopID = Int(string(raw["shopno"]))
        let slotStart = timestamp(raw["date_supply_rfc"] ?? raw["date_supply"])
        let slotEnd = timestamp(raw["date_supply_until_rfc"] ?? raw["date_supply_untill"])
        let clock = DateFormatter(); clock.timeZone = TimeZone(identifier: "Europe/Moscow"); clock.dateFormat = "HH:mm"
        deliverySlot = truth(raw["time_slot"]) ? [slotStart, slotEnd].compactMap { $0.map { clock.string(from: $0) } }.joined(separator: " — ") : ""
        let instruction = parcelBuyerInstruction(raw["comment_client"])
        let freeComments = parcelUniqueComments([string(raw["comment"]), string(raw["add_comment"])])
        buyerComments = parcelUniqueComments(freeComments + (parcelInstructionAlreadyWritten(instruction, in: freeComments) ? [] : [instruction]))
        var notes = [string(raw["comment_courier_address"])]
        if let metadata = raw["comments_address"] as? [String: Any], let rows = metadata["comments"] as? [[String: Any]] {
            notes += rows.map { string($0["comment"]) }
        }
        let buyer = Set(buyerComments.map(parcelCommentIdentity))
        courierComments = parcelUniqueComments(notes).filter { !buyer.contains(parcelCommentIdentity($0)) }
        let formattedAddress = ParcelAddress(raw)
        doorphone = formattedAddress.doorphone
        streetLine = formattedAddress.street
        detailsLine = formattedAddress.detailsLine
        address = formattedAddress.formatted

    }
}

// Official H7/z0e uses comment_client as a delivery-instruction code, not text.
func parcelBuyerInstruction(_ raw: Any?) -> String {
    let value = string(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let labels = ["4311": "Доставить лично", "4312": "Оставить у двери и позвонить", "4313": "Оставить у двери"]
    if let numeric = Double(value), numeric.isFinite {
        guard numeric >= 0, numeric <= 999_999, numeric.rounded() == numeric else { return "" }
        return labels[String(Int(numeric))] ?? ""
    }
    // Older responses can contain a human-readable instruction. Unknown numeric
    // codes are not useful customer comments and must not leak into the UI.
    return value
}

func parcelCommentIdentity(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).lowercased()
}

func parcelUniqueComments(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { raw in
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, seen.insert(parcelCommentIdentity(text)).inserted else { return nil }
        return text
    }
}

/// Omit only a redundant standard instruction. Free comments are never shortened
/// or discarded, so any extra instructions following the phrase remain visible.
func parcelInstructionAlreadyWritten(_ instruction: String, in comments: [String]) -> Bool {
    guard parcelCommentIdentity(instruction).trimmingCharacters(in: .punctuationCharacters) == "оставить у двери" else { return false }
    return comments.contains { text in
        let value = parcelCommentIdentity(text)
        let negative = value.range(of: #"(?:не|нельзя|не\s+нужно|не\s+надо)\s+остав"#, options: .regularExpression) != nil
        let positive = value.range(of: #"(?<![а-яё])остав(?:ить|ьте)\s+(?:заказ\s+)?у\s+двери(?![а-яё])"#, options: .regularExpression) != nil
        return positive && !negative
    }
}
