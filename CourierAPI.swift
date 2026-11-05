import Foundation
import CryptoKit

struct CourierAPI {
    let session: Session?
    var shopNumbers: [Int] = []
    var transport: URLSession = .shared
    static let root = "https://delivery-api.vkusvill.ru"
    static let authURL = "https://mobile-courier.vkusvill.ru/api/v1/couriers/auth/"
    static let coldControlNotification = Notification.Name("VVCourier.coldControlRequired")
    var sessionFingerprint: String? { session.map { SHA256.hash(data: Data(($0.courierID + ":" + $0.token).utf8)).map { String(format: "%02x", $0) }.joined() } }

    func request(_ url: String, body: [String: Any]? = nil, auth: Bool = true, method: String? = nil) async throws -> Any {
        let startedAt = Date()
        try Task.checkCancellation()
        guard let target = URL(string: url), target.scheme == "https" else { throw CourierError(message: "Некорректный адрес сервера.") }
        var request = URLRequest(url: target, timeoutInterval: 25)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("RHwyKgNlGDprL88wFQaVKngTDEQtUgDx", forHTTPHeaderField: "X-VKUSVILL-TOKEN")
        request.setValue("seagull_team", forHTTPHeaderField: "X-VKUSVILL-DEVICE")
        if auth {
            guard let session else { throw CourierError(message: "Сначала войди в аккаунт.", statusCode: 401) }
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        if let method { request.httpMethod = method }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw CourierError(message: "Не удалось связаться с ВВ. Проверь интернет и повтори обновление.") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CourierError(message: "Нет ответа ВВ.") }
        let result: Any? = data.isEmpty ? ([:] as [String: Any]) : (try? JSONSerialization.jsonObject(with: data))
        let dictionary = result as? [String: Any]
        let businessCode = dictionary.flatMap { integer($0["business_error"]) }
        let canSignal = auth && http.statusCode != 401 && http.statusCode != 403
        if canSignal, let dictionary, let required = ColdControlSignal.required(in: dictionary) {
            NotificationCenter.default.post(name: Self.coldControlNotification, object: nil, userInfo: ["required": required, "courierID": session?.courierID ?? "", "sessionFingerprint": sessionFingerprint ?? "", "startedAt": startedAt])
        }
        if businessCode == 102 && canSignal {
            if canSignal { NotificationCenter.default.post(name: Self.coldControlNotification, object: nil, userInfo: ["required": true, "courierID": session?.courierID ?? "", "sessionFingerprint": sessionFingerprint ?? "", "startedAt": startedAt]) }
            throw CourierError(message: "ВВ назначил фотоконтроль хладоэлементов. Открой задание в приложении.", statusCode: http.statusCode, businessCode: 102)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = http.statusCode == 401 ? "Сессия ВВ завершена. Войди заново, когда будешь готов. Новый код автоматически не запрашивается." : serverMessage(result) ?? (http.statusCode == 429 ? "ВВ временно ограничил частоту запросов. Подожди и повтори позже." : "ВкусВилл вернул ошибку \(http.statusCode). Повтори обновление позже.")
            throw CourierError(message: message, statusCode: http.statusCode, businessCode: businessCode)
        }
        guard let result else { throw CourierError(message: "ВВ вернул ответ в неизвестном формате.") }
        if let businessCode, businessCode != 0 {
            throw CourierError(message: serverMessage(result) ?? "ВкусВилл отклонил запрос. Обнови данные.", statusCode: http.statusCode, businessCode: businessCode)
        }
        if let dict = result as? [String: Any], meaningfulError(dict["error"]) {
            throw CourierError(message: serverMessage(dict) ?? "ВкусВилл отклонил запрос.")
        }
        return result
    }

    private func meaningfulError(_ value: Any?) -> Bool {
        if let rows = value as? [Any] { return !rows.isEmpty }
        if let dict = value as? [String: Any] { return !dict.isEmpty }
        return truth(value)
    }
    private func serverMessage(_ result: Any?) -> String? {
        if let text = result as? String, !text.isEmpty { return text }
        if let rows = result as? [Any] { return rows.compactMap(serverMessage).first }
        if let dict = result as? [String: Any] {
            for key in ["message", "error_message", "detail", "error"] { if let value = dict[key], let text = serverMessage(value), !text.isEmpty { return text } }
        }
        return nil
    }
    func dictionary(_ url: String, body: [String: Any]? = nil, auth: Bool = true, method: String? = nil) async throws -> [String: Any] {
        guard let value = try await request(url, body: body, auth: auth, method: method) as? [String: Any] else { throw CourierError(message: "Неожиданный ответ ВВ.") }
        return value
    }
    func requestCode(phone: String) async throws {
        _ = try await dictionary(Self.authURL, body: ["phone": phone], auth: false)
    }
    func login(phone: String, code: String) async throws -> Session {
        let result = try await dictionary(Self.authURL, body: ["phone": phone, "code": code], auth: false)
        guard let token = result["token"] as? String, !token.isEmpty, !string(result["id"]).isEmpty else { throw CourierError(message: "Код неверный или истёк.") }
        return Session(token: token, courierID: string(result["id"]))
    }
    func profile() async throws -> [String: Any] { try await dictionary(Self.root + "/v1/courier/courier") }
    func shops() async throws -> [Shop] {
        let result = try await dictionary(Self.root + "/v1/courier/shops")
        guard let rows = result["shops"] as? [[String: Any]] else { throw CourierError(message: "Не удалось прочитать список магазинов ВВ.") }
        var seen = Set<Int>()
        return rows.filter { !truth($0["invisible"]) }.compactMap(Shop.init).filter { seen.insert($0.id).inserted }.sorted {
            if $0.active != $1.active { return $0.active }
            return $0.id < $1.id
        }
    }
    func feed(_ feed: Feed, assembly: String = "all") async throws -> ParcelFeed {
        var numbers = shopNumbers
        if feed != .mine && numbers.isEmpty { numbers = try await shops().map(\.id) }
        if feed != .mine && numbers.isEmpty { return ParcelFeed(parcels: [], checking: [:], total: 0) }
        var result: [Parcel] = [], checking: [String: Any] = [:]
        var mapShops: [[String: Any]] = []
        var pagination = CourierPagination(limit: 100)
        repeat {
            try Task.checkCancellation()
            var body: [String: Any] = ["id_courier": session?.courierID ?? "", "pagination": ["offset": pagination.offset, "limit": pagination.limit]]
            if feed != .mine { body["shopno"] = numbers }
            if feed == .assembly {
                body["building"] = assembly == "all" || assembly == "building"; body["waiting"] = assembly == "all" || assembly == "waiting"; body["sloted"] = assembly == "all" || assembly == "sloted"
            }
            let data = try await dictionary(Self.root + "/v1/courier/" + feed.endpoint, body: body)
            guard let rows = data["parcels"] as? [[String: Any]] else { throw CourierError(message: "ВВ вернул список заказов в неизвестном формате.") }
            let page = try pagination.consume(rows, reportedTotal: data["total"])
            if let rules = data["checking"] as? [String: Any] {
                for (key, value) in rules {
                    if let nested = value as? [String: Any] {
                        var merged = checking[key] as? [String: Any] ?? [:]; merged.merge(nested) { _, new in new }; checking[key] = merged
                    } else { checking[key] = value }
                }
            }
            let map = data["map"] as? [String: Any] ?? [:]
            ParcelMapPayload.appendShops(map["shops"] as? [[String: Any]] ?? [], to: &mapShops)
            result += ParcelMapPayload.enrich(page.rows, map: map).map(Parcel.init)
            if page.complete { break }
            try Task.checkCancellation()
        } while true
        return ParcelFeed(parcels: result, checking: checking, total: max(pagination.total ?? 0, result.count), mapShops: mapShops)
    }
    func parcels(_ feed: Feed) async throws -> [Parcel] { try await self.feed(feed).parcels }
    func parcel(_ id: String) async throws -> Parcel {
        let data = try await dictionary(Self.root + "/v2/courier/get_parcel", body: ["id_courier": session?.courierID ?? "", "id_parcel": id])
        guard let raw = data["parcel"] as? [String: Any] else { throw CourierError(message: "Не удалось прочитать заказ.") }
        return Parcel(raw)
    }
    func activeShift() async throws -> Bool {
        let data = try await dictionary(Self.root + "/v1/courier/activity", body: ["id_courier": session?.courierID ?? ""])
        guard ["0", "1"].contains(string(data["res"])) else { throw CourierError(message: "Не удалось прочитать статус смены.") }
        return string(data["res"]) == "1"
    }
    func take(_ id: String) async throws {
        guard try await activeShift() else { throw CourierError(message: "Сначала начни смену.") }
        guard let parcel = try await parcels(.available).first(where: { $0.id == id }) else { throw CourierError(message: "Заказ больше недоступен.") }
        try await verifyQueuePickup(parcel)
        try await verifyPosition(parcel: parcel, action: "take")
        try await expectEmpty(Self.root + "/v2/courier/change_task_status", body: ["id_courier": session?.courierID ?? "", "id_parcel": id, "status": "pickuped"])
        guard try await parcels(.mine).contains(where: { $0.id == id }) else { throw CourierError(message: "ВВ принял запрос, но заказ пока не появился в «Мои». Обнови список перед повтором.") }
    }
    func incomes() async throws -> [(String, String)] {
        let data = try await dictionary("https://courier-rewards-calculation.vkusvill.ru/v1/rewards/payments/" + (session?.courierID ?? ""))
        guard let rows = data["items"] as? [[String: Any]] else { throw CourierError(message: "Не удалось прочитать чеки ВВ.") }
        return try rows.map {
            guard let amount = finiteNumber($0["total_amount"]) else { throw CourierError(message: "ВВ вернул некорректную сумму чека. Список не обновлён.") }
            return (String(string($0["operation_time"]).prefix(10)), String(format: "%.2f ₽", amount))
        }
    }
}
