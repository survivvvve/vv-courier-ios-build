import Foundation

// VV web contracts: My.checking declares the required method; a successful HTTP
// response alone does not mean that all packages have been inspected.
/// Owner + request generation reject late snapshots even for uncancelled button
/// Tasks, and prevent an old operation's readback from updating a new account.
struct InspectionRequestOwnership {
    struct Ticket: Equatable { let owner: String; let generation: UUID }
    private var current: Ticket?
    mutating func begin(owner: String) -> Ticket {
        let ticket = Ticket(owner: owner, generation: UUID()); current = ticket; return ticket
    }
    mutating func invalidate() { current = nil }
    func accepts(_ ticket: Ticket, owner: String, cancelled: Bool) -> Bool {
        !cancelled && ticket.owner == owner && current == ticket
    }
}

enum PackageInspectionRules {
    static func isCancelled(_ row: [String: Any]) -> Bool { truth(row["cancelled"]) }
    static func packageID(_ row: [String: Any]) -> String { string(row["id_package"]) }
    static func isChecked(_ row: [String: Any], after: Bool) -> Bool {
        let raw = row[after ? "check_after" : "check"]
        guard let value = integer(raw) else { return false }
        return [1, 2, 3].contains(value)
    }
    static func isFinished(_ response: [String: Any]) -> Bool {
        let value = string(response["is_finished"]).lowercased()
        return value == "1" || value == "true"
    }
    static func active(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.filter { !isCancelled($0) && !packageID($0).isEmpty }
    }
    static func allChecked(_ rows: [[String: Any]], after: Bool) -> Bool {
        let entries = active(rows)
        return !entries.isEmpty && entries.allSatisfy { isChecked($0, after: after) }
    }
    static func rejectBusinessError(_ result: [String: Any]) throws {
        if isFinished(result) { return }
        let message = string(result["error_message"] ?? result["message"])
        let code = number(result["code"] ?? result["business_error"])
        guard code == 0, string(result["error_message"]).isEmpty else {
            throw CourierError(message: message.isEmpty ? "ВВ не подтвердил проверку пакета. Обнови список перед повтором." : message)
        }
    }
}

extension CourierAPI {
    private func inspectionParcelID(_ parcelID: String) throws -> Int {
        guard let id = Int(parcelID), id > 0 else { throw CourierError(message: "Не удалось определить заказ для проверки пакетов.") }
        return id
    }

    /// Read-only POST from the first-party client. Returns only this parcel's rows.
    func packageRows(parcelID: String) async throws -> [[String: Any]] {
        let id = try inspectionParcelID(parcelID)
        let result = try await dictionary(Self.root + "/v1/courier/checking/get_packages", body: ["list_parcel": [id]])
        guard let rows = result["package_codes"] as? [[String: Any]] else { throw CourierError(message: "ВВ вернул список пакетов в неизвестном формате.") }
        var seen = Set<String>()
        return rows.filter { row in
            let belongs = string(row["id_parcel"]) == parcelID
            let package = PackageInspectionRules.packageID(row)
            return belongs && !package.isEmpty && seen.insert(package).inserted
        }
    }

    /// 0: no inspection required; 1: actual QR scan; 2: visual inspection.
    /// The website's DE/Uf selectors treat an absent requirement as NO_CHECK.
    /// Conflicting legacy parcel flags still fail closed rather than bypassing a check.
    func inspectionRequirement(parcelID: String, after: Bool) async throws -> Int {
        _ = try inspectionParcelID(parcelID)
        let current = try await feed(.mine)
        guard let parcel = current.parcels.first(where: { $0.id == parcelID }) else { throw CourierError(message: "Заказ больше не находится в «Мои». Обнови данные заказа.") }
        let raw: Any?
        if after {
            let rows = current.checking["parcels_packages_inspection_after"] as? [String: Any]
            raw = rows?[parcelID]
        } else { raw = current.checking["all_packages_inspection_before"] }
        if raw == nil {
            let keys = after ? ["check_after", "package_scan_after"] : ["check_before", "package_scan_before"]
            guard !keys.contains(where: { truth(parcel.raw[$0]) }) else { throw CourierError(message: "ВВ требует проверку пакетов, но не сообщил её способ. Обнови заказ.") }
            return 0
        }
        guard let value = Double(string(raw)), value.isFinite, value.rounded() == value, (0...2).contains(value) else {
            throw CourierError(message: "Не удалось определить обязательный способ проверки пакетов. Обнови заказ.")
        }
        return Int(value)
    }

    func scanPackage(parcelID: String, code: String, after: Bool) async throws -> [String: Any] {
        let parcel = try inspectionParcelID(parcelID)
        guard try await inspectionRequirement(parcelID: parcelID, after: after) == 1 else {
            throw CourierError(message: "ВВ изменил способ проверки. Обнови заказ перед продолжением.")
        }
        let scanned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = try await packageRows(parcelID: parcelID)
        guard let row = rows.first(where: { PackageInspectionRules.packageID($0) == scanned }) else {
            throw CourierError(message: "Этот QR-код не относится к пакетам выбранного заказа. Ничего не отправлено.")
        }
        guard !PackageInspectionRules.isCancelled(row) else { throw CourierError(message: "Этот пакет отменён. Не сканируй его для доставки.") }
        guard !PackageInspectionRules.isChecked(row, after: after) else { throw CourierError(message: "Этот пакет уже отмечен ВВ. Обнови список и продолжи с другим пакетом.") }
        let payload: [String: Any] = ["id_package": scanned, "check": 1, "reason": NSNull(), "after": after, "qr": NSNull(), "parcels": [parcel]]
        let result = try await dictionary(Self.root + "/v2/courier/checking/parcels/scan_package", body: payload)
        try PackageInspectionRules.rejectBusinessError(result)
        return result
    }

    /// For WITH_CHECK=2 before delivery only. It must never substitute for a scan.
    func markPackagesChecked(parcelID: String, ids: [String], checked: Bool) async throws {
        let parcel = try inspectionParcelID(parcelID)
        guard try await inspectionRequirement(parcelID: parcelID, after: false) == 2 else { throw CourierError(message: "ВВ не разрешает визуальную проверку вместо сканирования. Обнови заказ.") }
        let rows = try await packageRows(parcelID: parcelID)
        let known = Set(PackageInspectionRules.active(rows).map(PackageInspectionRules.packageID))
        let selected = Array(Set(ids))
        guard !selected.isEmpty, selected.allSatisfy({ known.contains($0) }) else { throw CourierError(message: "Список пакетов изменился. Обнови его перед подтверждением.") }
        let result = try await dictionary(Self.root + "/v1/courier/checking/parcels/check_packages", body: ["packages": selected, "id_parcel": parcel, "check": checked ? 1 : 0])
        try PackageInspectionRules.rejectBusinessError(result)
        let updated = try await packageRows(parcelID: parcelID)
        guard selected.allSatisfy({ id in
            updated.contains { PackageInspectionRules.packageID($0) == id && PackageInspectionRules.isChecked($0, after: false) == checked }
        }) else { throw CourierError(message: "ВВ пока не подтвердил отметку пакета. Обнови список, не повторяй действие сразу.") }
    }

    /// Read-only verification, usable by the order transition guards.
    func verifyPackageInspection(parcelID: String, after: Bool) async throws {
        let required = try await inspectionRequirement(parcelID: parcelID, after: after)
        if required == 0 { return }
        let rows = try await packageRows(parcelID: parcelID)
        guard PackageInspectionRules.allChecked(rows, after: after) else { throw CourierError(message: "ВВ ещё не подтвердил проверку всех пакетов этого заказа.") }
    }

    /// Explicit completion of visual inspection. Scan-mode cannot use check_all.
    func finishPackageInspection(parcelID: String, after: Bool, confirmedIDs: [String]? = nil) async throws {
        let parcel = try inspectionParcelID(parcelID)
        let requirement = try await inspectionRequirement(parcelID: parcelID, after: after)
        if requirement == 0 { return }
        guard requirement == 2 else { throw CourierError(message: "Для этого заказа требуется сканирование QR каждого пакета.") }
        if !after {
            try await verifyPackageInspection(parcelID: parcelID, after: false)
            return
        }
        let rows = try await packageRows(parcelID: parcelID)
        let activeIDs = Set(PackageInspectionRules.active(rows).map(PackageInspectionRules.packageID))
        guard !activeIDs.isEmpty else { throw CourierError(message: "Список пакетов пуст. Обнови заказ перед завершением проверки.") }
        guard let confirmedIDs, Set(confirmedIDs) == activeIDs else { throw CourierError(message: "Список пакетов изменился. Обнови его и проверь новые пакеты перед подтверждением.") }
        let result = try await dictionary(Self.root + "/v2/courier/checking/parcels/check_all", body: ["list_parcel": [parcel], "after": 1])
        try PackageInspectionRules.rejectBusinessError(result)
        try await verifyPackageInspection(parcelID: parcelID, after: true)
    }
}


struct InspectionPackage: Identifiable {
    let parcelID: String
    let packageID: String
    let cell: String
    let checked: Bool
    let cancelled: Bool
    var id: String { parcelID + ":" + packageID }
}

struct InspectionSnapshot {
    let parcels: [Parcel]
    let rows: [[String: Any]]
    let mode: Int
    let after: Bool
    var parcelIDs: [String] { parcels.map(\.id) }
    var packages: [InspectionPackage] {
        rows.map { row in
            let packageID = PackageInspectionRules.packageID(row)
            let parcelID = string(row["id_parcel"])
            // `cells` is the scanner endpoint's real field. Detail packages use
            // `id_cell`; match the actual package ID before falling back to it.
            var cell = string(row["cells"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if cell.isEmpty { cell = string(row["id_cell"]) }
            if cell.isEmpty, let parcel = parcels.first(where: { $0.id == parcelID }) {
                for order in parcel.raw["orders"] as? [[String: Any]] ?? [] {
                    if let package = (order["packages"] as? [[String: Any]] ?? []).first(where: { string($0["id_package"]) == packageID }) {
                        cell = string(package["id_cell"]); break
                    }
                }
            }
            return InspectionPackage(parcelID: parcelID, packageID: packageID, cell: cell, checked: PackageInspectionRules.isChecked(row, after: after), cancelled: PackageInspectionRules.isCancelled(row))
        }
    }
    var allChecked: Bool {
        if mode == 0 { return true }
        if !after && parcels.contains(where: { parcel in
            parcel.status == "pickuped" && !truth(parcel.raw["has_partner_order"]) && !rows.contains { string($0["id_parcel"]) == parcel.id }
        }) { return false }
        return PackageInspectionRules.allChecked(rows, after: after)
    }
    func confirmsScan(_ code: String) -> Bool {
        mode == 0 || packages.contains { $0.packageID == code && !$0.cancelled && $0.checked }
    }
    var pending: [InspectionPackage] { packages.filter { !$0.cancelled && !$0.checked } }
    static func mode(checking: [String: Any], parcels: [Parcel], after: Bool) throws -> Int {
        let raw: Any?
        if after {
            let rules = checking["parcels_packages_inspection_after"] as? [String: Any]
            raw = parcels.first.flatMap { rules?[$0.id] }
        } else { raw = checking["all_packages_inspection_before"] }
        if raw == nil {
            let keys = after ? ["check_after", "package_scan_after"] : ["check_before", "package_scan_before"]
            guard !parcels.contains(where: { parcel in keys.contains { truth(parcel.raw[$0]) } }) else { throw CourierError(message: "ВВ требует проверку, но не сообщил её способ. Обнови «Мои».") }
            return 0
        }
        guard let mode = Int(string(raw)), (0...2).contains(mode) else { throw CourierError(message: "Неизвестный способ проверки ВВ. Обнови «Мои».") }
        return mode
    }
    func verifyMembership(_ expected: [String]) throws {
        guard !expected.isEmpty, Set(expected) == Set(parcelIDs) else { throw CourierError(message: "Состав взятых заказов изменился. Обнови проверку всей партии перед продолжением.") }
    }
}

struct InspectionSkipPolicy {
    let before: Bool
    let after: Bool
}
struct InspectionSkipReason: Identifiable {
    let id: String
    let text: String
    static func parse(_ rows: [[String: Any]]) -> [InspectionSkipReason] {
        var seen = Set<String>()
        return rows.compactMap { row in
            let id = string(row["id"]), text = string(row["reason"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !text.isEmpty, seen.insert(id).inserted else { return nil }
            return InspectionSkipReason(id: id, text: text)
        }
    }
}

/// Camera callback debounce only. It never confirms a package or changes state.
struct ScannerCodeGate {
    private var accepted: [String: TimeInterval] = [:]
    mutating func accept(_ raw: String, now: TimeInterval) -> String? {
        let code = raw.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        if let last = accepted[code], now - last < 1.2 { return nil }
        accepted = accepted.filter { now - $0.value < 10 }
        accepted[code] = now
        return code
    }
}

extension CourierAPI {
    func packageRows(parcelIDs: [String]) async throws -> [[String: Any]] {
        let ids = try parcelIDs.map(inspectionParcelID)
        guard !ids.isEmpty else { return [] }
        let result = try await dictionary(Self.root + "/v1/courier/checking/get_packages", body: ["list_parcel": ids])
        guard let rows = result["package_codes"] as? [[String: Any]] else { throw CourierError(message: "ВВ вернул список пакетов в неизвестном формате.") }
        let membership = Set(parcelIDs)
        var seen = Set<String>()
        return rows.filter { row in
            let parcel = string(row["id_parcel"]), package = PackageInspectionRules.packageID(row)
            return membership.contains(parcel) && !package.isEmpty && seen.insert(parcel + ":" + package).inserted
        }
    }
    func inspectionSnapshot(after: Bool = false, parcelID: String? = nil) async throws -> InspectionSnapshot {
        let feed = try await self.feed(.mine)
        let parcels = after ? feed.parcels.filter { $0.id == parcelID } : feed.parcels
        guard !parcels.isEmpty else { throw CourierError(message: "Заказы больше не находятся в «Мои». Обнови список.") }
        let mode = try InspectionSnapshot.mode(checking: feed.checking, parcels: parcels, after: after)
        let rows = mode == 0 ? [] : try await packageRows(parcelIDs: parcels.map(\.id))
        return InspectionSnapshot(parcels: parcels, rows: rows, mode: mode, after: after)
    }
    func inspectionSkipPolicies() async throws -> [Int: InspectionSkipPolicy] {
        let response = try await dictionary(Self.root + "/v1/courier/shops")
        guard let shops = response["shops"] as? [[String: Any]] else { throw CourierError(message: "ВВ не передал разрешения на пропуск сканирования.") }
        var policies: [Int: InspectionSkipPolicy] = [:]
        for shop in shops {
            guard let id = Int(string(shop["shopno"])) else { continue }
            policies[id] = InspectionSkipPolicy(before: truth(shop["skip_scan_before"]), after: truth(shop["skip_scan_after"]))
        }
        return policies
    }
    func inspectionSkipReasons() async throws -> [InspectionSkipReason] {
        let result = try await dictionary(Self.root + "/v1/courier/checking/package_codes_reasons")
        guard let rows = result["reasons"] as? [[String: Any]] else { throw CourierError(message: "ВВ не вернул причины пропуска. Обнови список.") }
        return InspectionSkipReason.parse(rows)
    }
    /// Every write checks the entire current batch and sends it unchanged to VV.
    /// A new pickup invalidates the old batch; a prior HTTP timeout is never retried here.
    func scanInspectionPackage(expectedIDs: [String], code: String, after: Bool = false, parcelID: String? = nil, ttPackageID: String? = nil, reasonID: String? = nil, customReason: String? = nil) async throws -> [String: Any] {
        let snapshot = try await inspectionSnapshot(after: after, parcelID: parcelID)
        try snapshot.verifyMembership(expectedIDs)
        guard snapshot.mode == 1 else { throw CourierError(message: "ВВ изменил способ проверки. Обнови список пакетов.") }
        let rawCode = code.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let packageID = ttPackageID ?? rawCode
        let matching = snapshot.packages.filter { $0.packageID == packageID }
        guard matching.count == 1, let package = matching.first, !package.cancelled else { throw CourierError(message: "Стикер не относится к однозначно определённым активным пакетам этой партии. Ничего не отправлено.") }
        guard !package.checked else { throw CourierError(message: "Пакет уже подтверждён ВВ. Обнови список и выбери другой.") }
        var check = 1, reason: Any = NSNull(), qr: Any = NSNull()
        if ttPackageID != nil {
            guard !after, !rawCode.isEmpty else { throw CourierError(message: "Нужен настоящий QR-код ТТ от куратора.") }
            check = 3; qr = rawCode
        }
        if let reasonID {
            guard ttPackageID == nil else { throw CourierError(message: "Выбери один способ подтверждения пакета.") }
            let policies = try await inspectionSkipPolicies()
            let shop = snapshot.parcels.first(where: { $0.id == package.parcelID })?.shopID
            let policy = shop.flatMap { policies[$0] }
            guard after ? policy?.after == true : policy?.before == true else { throw CourierError(message: after ? "ВВ не разрешает пропуск у покупателя. Обратись к куратору." : "Для этого магазина нужен QR-код ТТ от куратора.") }
            if reasonID == "-1" {
                let text = (customReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw CourierError(message: "Укажи причину пропуска.") }
                reason = text
            } else {
                guard let item = try await inspectionSkipReasons().first(where: { $0.id == reasonID }) else { throw CourierError(message: "Причина больше недоступна в ВВ. Обнови список.") }
                reason = item.text
            }
            check = 2
        }
        let payload: [String: Any] = ["id_package": packageID, "check": check, "reason": reason, "after": after, "qr": qr, "parcels": try expectedIDs.map(inspectionParcelID)]
        try Task.checkCancellation()
        let response = try await dictionary(Self.root + "/v2/courier/checking/parcels/scan_package", body: payload)
        try PackageInspectionRules.rejectBusinessError(response)
        return response
    }
    func verifyBatchInspection(expectedIDs: [String]) async throws {
        let snapshot = try await inspectionSnapshot()
        try snapshot.verifyMembership(expectedIDs)
        guard snapshot.allChecked else { throw CourierError(message: "Сначала отсканируй или согласуй с ВВ все пакеты взятых заказов.") }
    }
}


// First-party Uge/UPe/Qge: partner pickup is a separate confirmation of each
// real suborder, not a fake package scan or a replacement for payment/receipt.
struct PartnerPickupSuborder: Identifiable {
    let id: String
    let checked: Bool
    let packageCount: Int?
    let weight: Double?
    var label: String { String(id.suffix(5)) }
}
struct PartnerPickupGroup: Identifiable {
    let id: String
    let title: String
    let address: String
    let isPartner: Bool
    let raw: [String: Any]
    let suborders: [PartnerPickupSuborder]
}
struct PartnerPickupSnapshot {
    let parcel: Parcel
    let groups: [PartnerPickupGroup]
    let requiresArrival: Bool
    let requiresDistance: Bool
    var allChecked: Bool { !groups.isEmpty && groups.allSatisfy { !$0.suborders.isEmpty && $0.suborders.allSatisfy(\.checked) } }
    static func parse(_ response: [String: Any], parcel: Parcel, requiresArrival: Bool = false, requiresDistance: Bool = false) throws -> PartnerPickupSnapshot {
        guard let addresses = response["parcel_addresses"] as? [[String: Any]], !addresses.isEmpty else { throw CourierError(message: "ВВ не передал точки выдачи партнёрского заказа. Обнови данные.") }
        var seen = Set<String>()
        let groups = try addresses.enumerated().map { index, address -> PartnerPickupGroup in
            guard let rows = address["suborders"] as? [[String: Any]], !rows.isEmpty else { throw CourierError(message: "ВВ не передал подзаказы точки выдачи. Обнови данные.") }
            let suborders = try rows.map { row -> PartnerPickupSuborder in
                let id = [row["order_id"], row["id_order"]].map(string).first(where: { (Int($0) ?? 0) > 0 }) ?? ""
                let checked = string(row["check"]).lowercased()
                guard let numericID = Int(id), numericID > 0, seen.insert(id).inserted, ["0", "1", "true", "false"].contains(checked) else { throw CourierError(message: "ВВ вернул неоднозначные данные подзаказа. Обнови выдачу партнёра.") }
                let count = Int(string(row["collected_pkgs"]))
                let weight = Double(string(row["order_weight"]).replacingOccurrences(of: ",", with: "."))
                return PartnerPickupSuborder(id: id, checked: ["1", "true"].contains(checked), packageCount: count.flatMap { $0 > 0 ? $0 : nil }, weight: weight.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
            }
            let partnerID = string(address["id_partner"])
            let title = firstAddressText(address["partner_name"], address["shopno_name"])
            return PartnerPickupGroup(id: "point-\(index)", title: title.isEmpty ? (partnerID.isEmpty ? "Магазин" : "Партнёр " + partnerID) : title, address: string(address["user_address"]), isPartner: !partnerID.isEmpty && partnerID != "0", raw: address, suborders: suborders)
        }
        return PartnerPickupSnapshot(parcel: parcel, groups: groups, requiresArrival: requiresArrival, requiresDistance: requiresDistance)
    }
}
struct PartnerArrivalReceipt {
    let parcelID: String
    let orderID: String
    fileprivate let at: Date
    fileprivate init(parcelID: String, orderID: String) { self.parcelID = parcelID; self.orderID = orderID; at = Date() }
}

extension CourierAPI {
    func partnerPickupSnapshot(parcelID: String) async throws -> PartnerPickupSnapshot {
        guard let parcel = try await feed(.mine).parcels.first(where: { $0.id == parcelID }), truth(parcel.raw["has_partner_order"]) else { throw CourierError(message: "Партнёрский заказ больше не находится в «Мои».") }
        _ = try inspectionParcelID(parcelID)
        let response = try await dictionary(Self.root + "/v1/courier/checking/partner_orders/" + parcelID)
        let flags = try await taskFlags()
        let result = try await dictionary(Self.root + "/v1/courier/shops")
        guard let shops = result["shops"] as? [[String: Any]], let shop = shops.first(where: { Int(string($0["shopno"])) == parcel.shopID }) else { throw CourierError(message: "ВВ не передал правила выдачи магазина. Обнови данные.") }
        return try PartnerPickupSnapshot.parse(response, parcel: parcel, requiresArrival: flags.contains(261), requiresDistance: truth(shop["get_order_check"]))
    }
    private func partnerPoint(_ snapshot: PartnerPickupSnapshot, orderID: String) throws -> PartnerPickupGroup {
        guard snapshot.parcel.status == "pickuped", let group = snapshot.groups.first(where: { $0.suborders.contains { $0.id == orderID } }) else { throw CourierError(message: "Подзаказ или статус изменился. Обнови выдачу партнёра.") }
        return group
    }
    private func verifyPartnerPoint(_ group: PartnerPickupGroup, required: Bool) async throws {
        guard required, group.isPartner else { return }
        guard let point = GeoPoint(group.raw, latitudeKeys: ["shop_lat"], longitudeKeys: ["shop_lon"]) else { throw CourierError(message: "ВВ не передал координаты партнёрской точки для обязательной проверки.") }
        let position = try await LocationService.shared.position()
        guard position.distance(from: point.location) <= 500 else { throw CourierError(message: "Подойди к партнёрской точке: выдача подтверждается в пределах 500 м.") }
    }
    func arriveAtPartner(parcelID: String, orderID: String) async throws -> PartnerArrivalReceipt {
        let snapshot = try await partnerPickupSnapshot(parcelID: parcelID)
        let group = try partnerPoint(snapshot, orderID: orderID)
        guard snapshot.requiresArrival else { throw CourierError(message: "ВВ не требует отдельной отметки прибытия. Обнови экран и подтверди выдачу.") }
        try await verifyPartnerPoint(group, required: snapshot.requiresDistance)
        guard let order = Int(orderID), order > 0 else { throw CourierError(message: "Некорректный номер подзаказа.") }
        try Task.checkCancellation()
        let response = try await dictionary(Self.root + "/v1/partner/arrive/\(order)", method: "POST")
        guard response.isEmpty else { throw CourierError(message: "ВВ не подтвердил прибытие. Обнови состояние перед повтором.") }
        return PartnerArrivalReceipt(parcelID: parcelID, orderID: orderID)
    }
    func confirmPartnerPickup(parcelID: String, orderID: String, checked: Bool, arrival: PartnerArrivalReceipt? = nil) async throws {
        let snapshot = try await partnerPickupSnapshot(parcelID: parcelID)
        let group = try partnerPoint(snapshot, orderID: orderID)
        guard group.suborders.first(where: { $0.id == orderID })?.checked != checked else { return }
        if checked && snapshot.requiresArrival {
            guard let arrival, arrival.parcelID == parcelID, arrival.orderID == orderID, Date().timeIntervalSince(arrival.at) < 600 else { throw CourierError(message: "Сначала отметь «Прибыл за заказом» у этого подзаказа.") }
        }
        try await verifyPartnerPoint(group, required: snapshot.requiresDistance)
        try Task.checkCancellation()
        let response = try await dictionary(Self.root + "/v1/courier/checking/update_partner_order", body: ["parcel_id": try inspectionParcelID(parcelID), "order_id": try inspectionParcelID(orderID), "check": checked])
        try PackageInspectionRules.rejectBusinessError(response)
        let updated = try await partnerPickupSnapshot(parcelID: parcelID)
        guard updated.groups.flatMap(\.suborders).first(where: { $0.id == orderID })?.checked == checked else { throw CourierError(message: "Запрос принят, но ВВ пока не подтвердил выдачу. Обнови состояние без повторной отправки.") }
    }
    func verifyPartnerPickupReady(_ parcel: Parcel) async throws {
        guard truth(parcel.raw["has_partner_order"]) else { return }
        _ = try inspectionParcelID(parcel.id)
        let response = try await dictionary(Self.root + "/v1/courier/checking/partner_orders/" + parcel.id)
        let snapshot = try PartnerPickupSnapshot.parse(response, parcel: parcel)
        guard snapshot.allChecked else { throw CourierError(message: "Подтверди все подзаказы партнёра в карточке заказа " + parcel.label + " перед началом доставки.") }
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// The before-delivery screen always covers all My orders, even when opened
/// from a single order. After-delivery remains scoped to its actual recipient.
struct ParcelInspectionView: View {
    let parcel: Parcel
    let after: Bool
    let mode: Int
    let onFinished: () -> Void
    var body: some View {
        InspectionBatchView(after: after, parcelID: after ? parcel.id : nil, onFinished: onFinished)
    }
}
#endif
