import Foundation
import CoreFoundation

struct ParcelActionIntent: Identifiable {
    let id = UUID()
    let action: String
    let parcelID: String
    let expectedStatus: String
    let identity: String
    let demo: Bool
    var reasonID: String? = nil
    var reasonText: String? = nil

    func validate(identity currentIdentity: String, parcelID currentParcel: String, status currentStatus: String) throws {
        guard identity == currentIdentity else { throw CancellationError() }
        guard parcelID == currentParcel, expectedStatus == currentStatus else { throw CourierError(message: "Заказ изменился. Обнови его и выбери действие заново.") }
    }
}

enum ShiftActionRules {
    static func missingEquipment(_ result: [String: Any]) throws -> [String] {
        guard let equipment = result["tmc"] as? [String: Any] else { throw CourierError(message: "ВВ не сообщил результат проверки оборудования. Начало смены недоступно.") }
        var missing: [String] = []
        for (name, value) in equipment {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw CourierError(message: "ВВ вернул неизвестный статус оборудования. Обнови проверку.") }
            if !flag.boolValue { missing.append(name) }
        }
        return missing.sorted()
    }
    static func validateSchedule(_ rows: [[String: Any]], at serverTime: Date) throws {
        let entries = normalizeSchedule(rows)
        guard !entries.isEmpty else { throw CourierError(message: "Нет запланированного выхода. Сначала запишись в график.") }
        let intervals = entries.compactMap(\.interval)
        guard intervals.count == entries.count else { throw CourierError(message: "ВВ вернул неизвестное время выхода. Обнови график перед началом смены.") }
        guard intervals.contains(where: { $0.0 <= serverTime.addingTimeInterval(3600) && $0.1 > serverTime }) else { throw CourierError(message: "Начать смену можно не раньше чем за 1 час до запланированного выхода.") }
    }
    static func returnReason(_ reason: [String: Any], typed: String?) throws -> String {
        if integer(reason["id"]) == 0 {
            let text = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CourierError(message: "Напиши конкретную причину возврата для пункта «Другое».") }
            return text
        }
        return string(reason["return_reason"])
    }
}

extension CourierAPI {
    func taskFlags() async throws -> Set<Int> {
        let result = try await request(Self.root + "/v1/tasks/active")
        guard let rows = result as? [Any] else { throw CourierError(message: "Не удалось прочитать обязательные проверки ВВ.") }
        return Set(rows.compactMap { Int(string($0)) })
    }

    func changeShift(active: Bool) async throws {
        let wasActive = try await activeShift()
        if wasActive == active {
            if !active { try await clearQueueAfterClosedShift() }
            return
        }
        if active {
            let profile = try await dictionary(Self.root + "/v1/courier/courier")
            guard truth(profile["courier_active"]) else { throw CourierError(message: "Аккаунт курьера не активен.") }
            let flags = try await taskFlags()
            var checks: [String] = []
            if let consent = profile["ppd_accepted"], !truth(consent) { checks.append("Согласие на обработку данных") }
            if flags.contains(124) {
                let result = try await dictionary("https://courier-profile.vkusvill.ru/v1/photo_control/status")
                if truth(result["blocking_work"]) && !truth(result["complited"]) { checks.append("Фотоконтроль") }
            }
            if flags.contains(184) {
                let url = flags.contains(250) ? "https://courier-profile.vkusvill.ru/v1/couriers/me/iot-check" : "https://rnis-service.vkusvill.ru/v1/couriers/check_iot"
                if truth(try await dictionary(url)["check_iot"]) { checks.append("Инструктаж") }
            }
            if flags.contains(182) {
                let result = try await dictionary("https://rnis-service.vkusvill.ru/v1/couriers/consent_mosru_test")
                if !truth(result["consent"]) { checks.append("Тестирование") }
            }
            if flags.contains(311) {
                let result = try await dictionary("https://rnis-service.vkusvill.ru/v1/couriers/atc-document-consent")
                if let item = result["item"] as? [String: Any], !item.isEmpty, !truth(item["atc_accepted"]) { checks.append("Требования АТК") }
            }
            if flags.contains(132) {
                let result = try await dictionary("https://courier-profile.vkusvill.ru/v1/courier/medbook")
                if truth(result["show_reminder"]) && !truth(result["active_medbook"]) { checks.append("Медицинская книжка") }
            }
            if flags.contains(280) || flags.contains(357) {
                let url = flags.contains(357) ? "https://couriers-schedules.vkusvill.ru/v1/couriers/me/schedules/slots/assignments" : "https://courier-profile.vkusvill.ru/v1/courier/me/schedule?version=1"
                let schedule = try await dictionary(url)
                let rows = schedule["schedules"] as? [[String: Any]] ?? schedule["items"] as? [[String: Any]] ?? []
                let serverTime = try await shiftServerTime()
                try ShiftActionRules.validateSchedule(rows, at: serverTime)
            }
            if flags.contains(175) {
                let required = try await dictionary("https://courier-profile.vkusvill.ru/v1/courier/me/required_tmc")
                let missing = try ShiftActionRules.missingEquipment(required)
                if !missing.isEmpty { checks.append("Получить и подтвердить оборудование: " + missing.joined(separator: ", ")) }
            }
            if !checks.isEmpty { throw CourierError(message: "Перед началом смены нужно: " + checks.joined(separator: "; ") + ".") }
            if flags.contains(164) { try await acknowledgeKisArtShift(flags: flags) }
        } else {
            guard try await parcels(.mine).isEmpty else { throw CourierError(message: "Сначала доставь или верни все взятые заказы.") }
            let terminal = try await terminalStatus()
            guard let result = integer(terminal["res"]), result >= 0 else { throw CourierError(message: "ВВ не подтвердил статус терминала. Обнови его перед завершением смены.") }
            let terminalID = string(terminal["terminal_id"])
            guard terminalID.isEmpty || terminalID == "0" else { throw CourierError(message: "Сначала сдай закреплённый терминал №" + terminalID + ". После сдачи обнови его статус.") }
            guard result != 0 && result != 2 else { throw CourierError(message: "Статус закреплённого терминала неполный. Обнови его перед завершением смены.") }
        }
        do {
            let result = try await dictionary(Self.root + "/v2/courier/session_courier", body: ["id_courier": session?.courierID ?? "", "shift": active ? 1 : 0, "id_status": active ? 5 : 6])
            guard result["business_error"] == nil, result["message"] == nil, !string(result["description"]).isEmpty else { throw CourierError(message: "ВВ не подтвердил смену. Обнови статус перед повторной попыткой.") }
        } catch is CancellationError { throw CancellationError() }
        catch {
            let failure = error as? CourierError
            // A timeout may follow a successful write. Never replay the shift request.
            if !active, (failure?.statusCode == nil || (failure?.statusCode ?? 0) >= 500), let actual = try? await activeShift(), !actual {
                try await clearQueueAfterClosedShift()
                return
            }
            if failure?.statusCode == nil || (failure?.statusCode ?? 0) >= 500 {
                throw CourierError(message: "Ответ на изменение смены не подтверждён. Смена могла измениться: обнови статус, не повторяй действие сразу.")
            }
            throw error
        }
        guard try await activeShift() == active else { throw CourierError(message: "Статус пока не обновился. Не повторяй действие сразу.") }
        if !active { try await clearQueueAfterClosedShift() }
    }

    /// The official /time returns text and is the clock used for the one-hour gate.
    func shiftServerTime() async throws -> Date {
        var request = URLRequest(url: URL(string: Self.root + "/time")!, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw CourierError(message: "Не удалось получить время ВВ. Обнови проверку перед началом смены.") }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let date = timestamp(text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) else {
            throw CourierError(message: "ВВ вернул неизвестное серверное время. Начало смены недоступно.")
        }
        return date
    }

    private func acknowledgeKisArtShift(flags: Set<Int>) async throws {
        let version = flags.contains(267) ? 2 : 1
        let courier: Any = integer(session?.courierID).map { $0 as Any } ?? (session?.courierID ?? "")
        let result = try await dictionary("https://rnis-service.vkusvill.ru/v\(version)/rnis-provider/start_shift", body: ["courier_id": courier])
        let status = string(result["status"])
        guard status == "ok" else {
            let descriptions = ["inactive_warning": "Нужна регистрация или проверка данных КИС АРТ", "inactive_blocked": "КИС АРТ не разрешил открыть смену", "already_registred": "КИС АРТ сообщает о существующей регистрации или смене", "validation_error": "КИС АРТ требует исправить данные", "error": "КИС АРТ отклонил проверку", "upload_photos_failed": "КИС АРТ не получил обязательные фотографии", "503": "КИС АРТ временно недоступен", "200": "КИС АРТ не подтвердил допуск к смене"]
            let detail = string(result["message"])
            throw CourierError(message: (descriptions[status] ?? "КИС АРТ вернул неизвестный статус допуска") + (detail.isEmpty ? "." : ": " + detail))
        }
    }

    /// Removal belongs to confirmed closure, never to an attempted shift write.
    private func clearQueueAfterClosedShift() async throws {
        let courier = session?.courierID ?? ""
        do {
            let url = Self.root + "/v3/courier/queue/clusters/" + courier
            let before = try await dictionary(url)
            guard let clusters = before["clusters"] as? [[String: Any]] else { throw CourierError(message: "Не удалось проверить очередь.") }
            guard clusters.contains(where: { truth($0["active_queue"]) }) else { return }
            do {
                let result = try await dictionary(Self.root + "/v2/courier/queue/" + courier, method: "DELETE")
                guard result.isEmpty else { throw CourierError(message: "ВВ не подтвердил выход из очереди.") }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Verify a potentially successful deletion without repeating it.
                let state = try await dictionary(url)
                guard let rows = state["clusters"] as? [[String: Any]], !rows.contains(where: { truth($0["active_queue"]) }) else { throw error }
                return
            }
            let state = try await dictionary(url)
            guard let rows = state["clusters"] as? [[String: Any]], !rows.contains(where: { truth($0["active_queue"]) }) else { throw CourierError(message: "ВВ ещё не подтвердил выход из очереди.") }
        } catch is CancellationError { throw CancellationError() }
        catch { throw CourierError(message: "Смена уже закрыта. Выход из очереди пока не подтверждён: обнови очередь и проверь своё участие. Повторное закрытие смены не требуется.") }
    }

    func reasons(before: Bool) async throws -> [[String: Any]] {
        let data = try await dictionary(Self.root + "/v1/tasks/get_return_reasons")
        guard let rows = data[before ? "before_delivery" : "after_delivery"] as? [[String: Any]] else { throw CourierError(message: "Не удалось прочитать причины возврата.") }
        return rows
    }

    func orderAction(_ id: String, action: String, reasonID: String? = nil, reasonText: String? = nil, expectedStatus: String? = nil) async throws {
        let mine = try await feed(.mine)
        guard mine.parcels.contains(where: { $0.id == id }) else { throw CourierError(message: "Заказ больше не находится в «Мои».") }
        if action == "start" { try await startDeliveryBatch(expectedParcelIDs: mine.parcels.map(\.id)); return }
        let data = try await dictionary(Self.root + "/v2/courier/get_parcel", body: ["id_courier": session?.courierID ?? "", "id_parcel": id])
        guard let parcel = data["parcel"] as? [String: Any] else { throw CourierError(message: "Не удалось прочитать заказ.") }
        let status = string(parcel["parcel_status"] ?? parcel["delivery_status"])
        if let expectedStatus, status != expectedStatus { throw CourierError(message: "Статус заказа изменился. Выбери действие заново.") }
        let transitions: [String: ([String], String)] = [
            "start": (["pickuped"], "on_the_way"), "arrived": (["on_the_way"], "arrived"),
            "deliver": (["on_the_way", "arrived"], "delivered"), "cancel": (["pickuped", "on_the_way", "arrived"], ""),
            "returned": (["on_return", "awaiting_return", "awaiting_deletion"], "returned"), "resume": (["on_return"], "on_the_way")
        ]
        guard let transition = transitions[action], transition.0.contains(status) else { throw CourierError(message: "Статус изменился. Обнови «Мои».") }
        if ["deliver", "arrived", "returned"].contains(action) { try await verifyPosition(parcel: Parcel(parcel), action: action) }
        var version = 2
        var params: [String: Any] = ["id_courier": session?.courierID ?? "", "id_parcel": id, "status": transition.1]
        if action == "deliver" {
            guard let pay = Int(string(parcel["pay_way"])), [0, 2, 5].contains(pay) else { throw CourierError(message: "Оплата этого заказа ещё не подтверждена. Закрытие недоступно.") }
            try await verifyPackageInspection(parcelID: id, after: true)
            params["pay_way"] = pay
            params["sum_pay"] = string(parcel["pay_summ"] ?? 0)
            version = 3
        }
        if action == "cancel" {
            let before = status == "pickuped"
            let rows = try await reasons(before: before)
            guard let reasonID, let reason = rows.first(where: { string($0["id"]) == reasonID }), let numericID = Int(id) else { throw CourierError(message: "Выбери действительную причину возврата.") }
            let comment = try ShiftActionRules.returnReason(reason, typed: reasonText)
            try await expectEmpty(Self.root + "/v1/tasks/set_task_return_reason", body: ["courier_id": Int(session?.courierID ?? "") as Any? ?? session?.courierID ?? "", "order_id": numericID, "reason_id": reason["id"] ?? reasonID, "return_reason": comment, "before_delivery": before])
            params["status"] = before ? "reposted" : "on_return"
        }
        if action == "returned", ["awaiting_return", "awaiting_deletion"].contains(status) { params["status"] = "returned_after_deletion" }
        try await expectEmpty(Self.root + "/v\(version)/courier/change_task_status", body: params)
        let updated = try await parcels(.mine).first(where: { $0.id == id })
        let target = string(params["status"])
        if ["delivered", "returned", "returned_after_deletion", "reposted"].contains(target) {
            guard updated == nil || updated?.status == target else { throw CourierError(message: "ВВ принял действие, но статус ещё не обновился. Обнови заказ перед повтором.") }
        } else {
            guard updated?.status == target else { throw CourierError(message: "ВВ принял действие, но новый статус ещё не подтверждён. Обнови заказ перед повтором.") }
        }
    }

    /// Mirrors first-party x2/t2: one departure request, then serial status
    /// transitions for pickuped orders. Each mutation is confirmed by readback;
    /// uncertain failures stop the series without replaying any mutation.
    func startDeliveryBatch(expectedParcelIDs: [String]) async throws {
        guard try await activeShift() else { throw CourierError(message: "Сначала начни смену.") }
        let snapshot = try await inspectionSnapshot()
        try snapshot.verifyMembership(expectedParcelIDs)
        guard snapshot.allChecked else { throw CourierError(message: "ВВ ещё не подтвердил все пакеты партии.") }
        let picked = snapshot.parcels.filter { $0.status == "pickuped" }
        guard !picked.isEmpty else { throw CourierError(message: "В этой партии нет заказов для начала доставки. Обнови «Мои».") }
        for parcel in picked { try await verifyPartnerPickupReady(parcel) }
        try Task.checkCancellation()
        let departure = try await dictionary(Self.root + "/v1/courier/start_delivery", method: "POST")
        try PackageInspectionRules.rejectBusinessError(departure)
        for parcel in picked {
            try Task.checkCancellation()
            let current = try await self.parcel(parcel.id)
            if current.status == "on_the_way" { continue }
            guard current.status == "pickuped" else { throw CourierError(message: "Статус заказа изменился во время старта. Обнови «Мои»; уже выполненные действия не повторяются.") }
            try await verifyPartnerPickupReady(current)
            try await expectEmpty(Self.root + "/v2/courier/change_task_status", body: ["id_courier": session?.courierID ?? "", "id_parcel": parcel.id, "status": "on_the_way"])
            let updated = try await parcels(.mine)
            guard Set(updated.map(\.id)) == Set(expectedParcelIDs), updated.first(where: { $0.id == parcel.id })?.status == "on_the_way" else { throw CourierError(message: "ВВ принял старт, но состав или статус партии ещё не подтверждён. Обнови «Мои» перед следующей попыткой.") }
        }
    }

    func expectEmpty(_ url: String, body: [String: Any]) async throws {
        guard try await dictionary(url, body: body).isEmpty else { throw CourierError(message: "ВВ не подтвердил действие. Обнови состояние перед повтором.") }
    }
}

func truth(_ value: Any?) -> Bool {
    !["", "0", "false", "none", "<null>"].contains(string(value).lowercased())
}
