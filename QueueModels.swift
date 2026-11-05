import Foundation

struct QueuePerson: Identifiable {
    let id: String
    let name: String
    let taken: Int
    let limit: Int
    let isMe: Bool
}

/// A queue has its own ID and name. Several queues may share the same shop.
struct QueueSummary: Identifiable {
    let id: String
    let title: String
    let shops: [Int]
    let orders: Int
    let courierCount: Int
    let isActive: Bool
    let locations: [GeoPoint]
    var requiresGeoCheck = false
    var requiresQR = false

    /// The server's name is preserved; do not append shop numbers already in it.
    var shopSubtitle: String? {
        let extra = shops.filter { shop in
            !title.split(whereSeparator: { !$0.isNumber }).contains(Substring(String(shop)))
        }
        return extra.isEmpty ? nil : "Магазин " + extra.map { "№\($0)" }.joined(separator: ", ")
    }
}

struct QueueSection: Identifiable {
    let summary: QueueSummary
    let orders: Int
    let terminalOrders: Int
    let people: [QueuePerson]
    let requiresQR: Bool
    var id: String { summary.id }
    var title: String { summary.title }
    var locations: [GeoPoint] { summary.locations }
}

/// Schema from the official web client: v3 clusters uses `name`, not shop numbers.
/// v4 detail's `data` is already ordered; never sort by FIO, count or courier ID.
enum QueueParser {
    static func catalog(_ data: [String: Any], shops filter: [Int] = []) throws -> [QueueSummary] {
        guard let rows = data["clusters"] as? [[String: Any]] else {
            throw CourierError(message: "ВВ не вернул список очередей. Обнови страницу позже.")
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            let id = string(row["cluster_id"])
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let rawShops = row["shops"] as? [[String: Any]] ?? []
            var seenShops = Set<Int>()
            let shops = rawShops.compactMap { Int(string($0["shop_number"])) }.filter { $0 > 0 && seenShops.insert($0).inserted }
            if !filter.isEmpty && !shops.contains(where: filter.contains) { return nil }
            let name = string(row["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return QueueSummary(id: id, title: name.isEmpty ? "Очередь №\(id)" : name, shops: shops,
                                orders: max(0, (integer(row["parcels_count"]) ?? 0)),
                                courierCount: max(0, (integer(row["count"]) ?? 0)),
                                isActive: truth(row["active_queue"]),
                                locations: rawShops.compactMap { GeoPoint($0, latitudeKeys: ["lat", "latitude"], longitudeKeys: ["lon", "longitude"]) },
                                requiresGeoCheck: truth(row["geo_check"]), requiresQR: truth(row["queue_qr_scan"]))
        }
    }

    static func detail(_ data: [String: Any], summary: QueueSummary, courierID: String?) throws -> QueueSection {
        guard let rows = data["data"] as? [[String: Any]] else {
            throw CourierError(message: "ВВ вернул неизвестный формат выбранной очереди. Попробуй обновить.")
        }
        var seen = Set<String>()
        var people: [QueuePerson] = []
        for row in rows {
            let id = string(row["courier_id"])
            guard !id.isEmpty else { throw CourierError(message: "В строке очереди нет идентификатора курьера. Обнови список.") }
            // A duplicated server row is not a second courier. Preserve first position.
            guard seen.insert(id).inserted else { continue }
            let name = string(row["fio"]).trimmingCharacters(in: .whitespacesAndNewlines)
            people.append(QueuePerson(id: id, name: name.isEmpty ? "Имя не указано" : name,
                                      taken: max(0, (integer(row["current_count"]) ?? 0)),
                                      limit: max(0, (integer(row["limit"]) ?? 0)), isMe: id == courierID))
        }
        return QueueSection(summary: summary,
                            orders: max(0, (integer(data["parcels_count"] ?? summary.orders) ?? 0)),
                            terminalOrders: max(0, (integer(data["parcels_count_terminal"]) ?? 0)),
                            people: people, requiresQR: truth(data["queue_qr_scan"] ?? summary.requiresQR))
    }
}

/// Mirrors the official take-order gate. It applies only to matching shop/gettype
/// descriptors in queues with take_check, and only for profiles with queue_check.
/// Membership is global (pooling_status.cluster_id), not tied to a guessed area.
enum QueuePickupRules {
    static func requiresMembership(parcel: [String: Any], profileQueueCheck: Bool, clusters: [[String: Any]]) -> Bool {
        guard profileQueueCheck, let shop = integral(parcel["shopno"]) else { return false }
        let orderType = integral(parcel["gettype"])
        return clusters.contains { cluster in
            guard truth(cluster["take_check"]), let shops = cluster["shops"] as? [[String: Any]] else { return false }
            return shops.contains { descriptor in
                guard integral(descriptor["shop_number"]) == shop, let type = integral(descriptor["gettype"]) else { return false }
                return type == 0 || orderType == type
            }
        }
    }
    static func hasMembership(_ response: [String: Any]) -> Bool {
        // The web client's fulfilled reducer uses truthiness of cluster_id.
        guard let id = integral(response["cluster_id"]) else { return false }
        return id != 0
    }
    private static func integral(_ value: Any?) -> Int? {
        guard let numeric = Double(string(value)), numeric.isFinite,
              numeric.rounded(.towardZero) == numeric, numeric > Double(Int.min), numeric < Double(Int.max) else { return nil }
        return Int(numeric)
    }
}

extension CourierAPI {
    func verifyQueuePickup(_ parcel: Parcel) async throws {
        let currentProfile = try await profile()
        guard truth(currentProfile["queue_check"]) else { return }
        // Use all fresh descriptors: UI shop selection must not alter eligibility.
        let data = try await dictionary(Self.root + "/v3/courier/queue/clusters/" + (session?.courierID ?? ""))
        guard let clusters = data["clusters"] as? [[String: Any]] else {
            throw CourierError(message: "Не удалось проверить правила очереди для этого заказа. Обнови данные.")
        }
        guard QueuePickupRules.requiresMembership(parcel: parcel.raw, profileQueueCheck: true, clusters: clusters) else { return }
        let status = try await dictionary(Self.root + "/v2/courier/pooling_status")
        guard QueuePickupRules.hasMembership(status) else { throw CourierError(message: "Для получения этого заказа необходимо встать в очередь.") }
    }

    func queueCatalog() async throws -> [QueueSummary] {
        let data = try await dictionary(Self.root + "/v3/courier/queue/clusters/" + (session?.courierID ?? ""))
        return try QueueParser.catalog(data, shops: shopNumbers)
    }

    func queueDetails(_ summary: QueueSummary) async throws -> QueueSection {
        guard !summary.id.isEmpty, summary.id.allSatisfy(\.isNumber) else { throw CourierError(message: "ВВ вернул неверный номер очереди.") }
        let data = try await dictionary(Self.root + "/v4/courier/queue/" + summary.id)
        return try QueueParser.detail(data, summary: summary, courierID: session?.courierID)
    }

    // Compatibility for aggregate overview callers. The actual QueueView loads only
    // its selected queue, so another queue's rows can never appear in that screen.
    func queueSections() async throws -> [QueueSection] {
        var result: [QueueSection] = []
        for summary in try await queueCatalog() {
            try Task.checkCancellation()
            result.append(try await queueDetails(summary))
        }
        return result
    }

    func queue() async throws -> [(String, String)] {
        try await queueSections().flatMap { section in
            [(section.title, "\(section.orders) заказов")] +
            (section.people.isEmpty ? [("В очереди никого нет", "")] : section.people.map { ($0.name, "\($0.taken)/\($0.limit)") })
        }
    }

    func changeQueue(_ id: String, join: Bool, qr: String? = nil) async throws {
        guard let summary = try await queueCatalog().first(where: { $0.id == id }) else {
            throw CourierError(message: "Эта очередь больше недоступна. Обнови список.")
        }
        let current = try await queueDetails(summary)
        let present = current.people.contains(where: \.isMe)
        if present == join { return }
        let courier = session?.courierID ?? ""
        if join {
            guard try await activeShift() else { throw CourierError(message: "Сначала начни смену, чтобы встать в очередь.") }
            if summary.requiresGeoCheck {
                guard !summary.locations.isEmpty else { throw CourierError(message: "ВВ не сообщил координаты магазина для входа в очередь. Повтори обновление позже.") }
                let position = try await LocationService.shared.position()
                guard summary.locations.contains(where: { position.distance(from: $0.location) < 200 }) else {
                    throw CourierError(message: "Для входа в эту очередь нужно находиться у магазина, ближе 200 м.")
                }
            }
            var body: [String: Any] = ["cluster_id": Int(id).map { $0 as Any } ?? id, "courier_id": Int(courier).map { $0 as Any } ?? courier]
            if current.requiresQR {
                guard let qr, !qr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CourierError(message: "Для этой очереди нужно отсканировать QR-код магазина.") }
                body = ["id_courier": courier, "id_cluster": id, "queue_qr_code": qr]
            }
            try await expectEmpty(Self.root + "/v2/courier/queue", body: body)
        } else {
            let result = try await dictionary(Self.root + "/v2/courier/queue/\(courier)/\(id)", method: "DELETE")
            guard result.isEmpty else { throw CourierError(message: "ВВ не подтвердил выход. Обнови очередь перед повтором.") }
        }
        // Verify the same ID, never the first queue returned after a mutation.
        let updated = try await queueDetails(summary)
        guard updated.people.contains(where: \.isMe) == join else {
            throw CourierError(message: "Запрос отправлен, но очередь пока не обновилась. Проверь список перед повтором.")
        }
    }
}

/// All sample data stays in memory. Queues deliberately share one store to catch
/// accidental merging by shop number during UI checks.
enum QueueDemo {
    static func catalog(joined: Set<String>) -> [QueueSummary] {
        [QueueSummary(id: "demo-north", title: "Парнас низ 101", shops: [101], orders: 4, courierCount: 2 + (joined.contains("demo-north") ? 1 : 0), isActive: joined.contains("demo-north"), locations: []),
         QueueSummary(id: "demo-south", title: "Парнас верх 101", shops: [101], orders: 2, courierCount: 1 + (joined.contains("demo-south") ? 1 : 0), isActive: joined.contains("demo-south"), locations: []),
         QueueSummary(id: "demo-empty", title: "Промзона 101", shops: [101], orders: 3, courierCount: joined.contains("demo-empty") ? 1 : 0, isActive: joined.contains("demo-empty"), locations: [])]
    }
    static func detail(_ summary: QueueSummary, joined: Set<String>, taken: Int) -> QueueSection {
        var people: [QueuePerson] = []
        if summary.id == "demo-north" {
            people = [QueuePerson(id: "demo-n1", name: "Демо-курьер Анна", taken: 2, limit: 6, isMe: false),
                      QueuePerson(id: "demo-n2", name: "Демо-курьер Иван", taken: 1, limit: 4, isMe: false)]
        } else if summary.id == "demo-south" {
            people = [QueuePerson(id: "demo-s1", name: "Демо-курьер Олег", taken: 3, limit: 5, isMe: false)]
        }
        if joined.contains(summary.id) { people.append(QueuePerson(id: "demo-me", name: "Ты", taken: taken, limit: 6, isMe: true)) }
        return QueueSection(summary: summary, orders: summary.orders, terminalOrders: 0, people: people, requiresQR: false)
    }
}
