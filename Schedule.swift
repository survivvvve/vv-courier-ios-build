import SwiftUI

struct ScheduleData {
    let editable: Bool
    let manual: Bool
    let minDate: String
    let maxDate: String
    let slots: [[String: Any]]
    // Keep all stores here: overlap checks must include the courier's other exits.
    let assigned: [[String: Any]]
    var entries: [ScheduleEntry] { normalizeSchedule(assigned) }
}

struct ScheduleEntry: Identifiable {
    let id: String
    let day: String
    let shopID: Int?
    let shopName: String
    let start: String
    let end: String
    var shopLabel: String {
        if !shopName.isEmpty { return shopName }
        return shopID.map { "Магазин №\($0)" } ?? "Магазин не указан ВВ"
    }
    var interval: (Date, Date)? { scheduleInterval(day: day, start: start, end: end) }
    var timeLabel: String {
        guard let interval else { return "Время не указано" }
        return scheduleTime(interval.0) + " — " + scheduleTime(interval.1) + (moscowDay(interval.0) == moscowDay(interval.1) ? "" : " · следующий день")
    }
}

func normalizeSchedule(_ rows: [[String: Any]]) -> [ScheduleEntry] {
    var entries: [ScheduleEntry] = []
    var seen = Set<String>()
    func visit(_ row: [String: Any], inheritedDay: String = "", inheritedShop: [String: Any] = [:]) {
        let day = string(row["date"]).isEmpty ? inheritedDay : string(row["date"])
        if let shops = row["shops"] as? [[String: Any]], !shops.isEmpty {
            for shop in shops { visit(shop, inheritedDay: day, inheritedShop: shop) }
        }
        let periods = row["slots"] as? [[String: Any]] ?? row["periods"] as? [[String: Any]]
        if let periods {
            for slot in periods {
                var enriched = slot
                if enriched["shopno"] == nil { enriched["shopno"] = row["shopno"] ?? inheritedShop["shopno"] }
                if enriched["shop_name"] == nil { enriched["shop_name"] = row["shop_name"] ?? inheritedShop["shop_name"] }
                visit(enriched, inheritedDay: day, inheritedShop: inheritedShop)
            }
            return
        }
        let from = string(row["time_from"] ?? row["start"])
        let to = string(row["time_to"] ?? row["end"])
        guard !from.isEmpty || !to.isEmpty else { return }
        let shop = row["shop"] as? [String: Any] ?? [:]
        let shopID = Int(string(row["shopno"] ?? row["shop_number"] ?? shop["id"] ?? inheritedShop["shopno"]))
        let name = string(row["shop_name"] ?? shop["name"] ?? inheritedShop["shop_name"])
        let entryDay = day.isEmpty && from.count >= 10 ? String(from.prefix(10)) : day
        let identity = [entryDay, string(shopID), string(row["id"] ?? row["slot_id"]), from, to].joined(separator: "|")
        guard seen.insert(identity).inserted else { return }
        entries.append(ScheduleEntry(id: identity, day: entryDay, shopID: shopID, shopName: name, start: from, end: to))
    }
    rows.forEach { visit($0) }
    return entries.sorted { ($0.day, $0.start, $0.shopID ?? 0) < ($1.day, $1.start, $1.shopID ?? 0) }
}

func scheduleInterval(day: String, start: String, end: String) -> (Date, Date)? {
    func parse(_ raw: String) -> Date? {
        if raw.count > 8 { return timestamp(raw) }
        let time = raw.count == 5 ? raw + ":00" : raw
        if time == "24:00:00", let midnight = timestamp(day + "T00:00:00") { return midnight.addingTimeInterval(86400) }
        return timestamp(day + "T" + time)
    }
    guard let beginning = parse(start), var ending = parse(end) else { return nil }
    if ending < beginning {
        guard end.count <= 8 else { return nil }
        ending = ending.addingTimeInterval(86400)
    }
    guard ending > beginning else { return nil }
    return (beginning, ending)
}

func scheduleTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

enum ScheduleTimes {
    // The current VV selector offers half-hour steps and a final 23:59 end.
    static let starts = (0..<48).map { String(format: "%02d:%02d", $0 / 2, ($0 % 2) * 30) }
    static let ends = starts + ["23:59"]
}

struct ScheduleBookingResult {
    let assignments: [[String: Any]]?
    let acknowledged: Bool
    let readbackSucceeded: Bool
    let message: String
}

func scheduleContains(_ rows: [[String: Any]], shopID: Int, day: String, start: String, end: String) -> Bool {
    guard let expected = scheduleInterval(day: day, start: start, end: end) else { return false }
    return normalizeSchedule(rows).contains { entry in
        guard entry.shopID == shopID, let actual = entry.interval else { return false }
        // Read responses may include seconds; booking itself has minute precision.
        return abs(floor(actual.0.timeIntervalSince1970 / 60) - floor(expected.0.timeIntervalSince1970 / 60)) < 1
            && abs(floor(actual.1.timeIntervalSince1970 / 60) - floor(expected.1.timeIntervalSince1970 / 60)) < 1
    }
}

extension CourierAPI {
    static let scheduleRoot = "https://couriers-schedules.vkusvill.ru/v1/couriers"
    func scheduleAssignments() async throws -> [[String: Any]] {
        let result = try await dictionary("https://couriers-schedules.vkusvill.ru/v2/couriers/me/schedule")
        guard let rows = result["items"] as? [[String: Any]] else { throw CourierError(message: "ВВ вернул график в неизвестном формате.") }
        return rows
    }
    func schedule(day: String) async throws -> ScheduleData {
        guard let date = timestamp(day + "T00:00:00"), moscowDay(date) == day else { throw CourierError(message: "Выбери корректную дату выхода.") }
        let editable = try await dictionary(Self.scheduleRoot + "/me/schedule/editability")
        try Task.checkCancellation()
        let assignedRows = try await scheduleAssignments()
        let free = try await dictionary(Self.scheduleRoot + "/me/schedules/limited-slots/free?date_from=\(day)&date_to=\(day)")
        let flags = try await taskFlags()
        try Task.checkCancellation()
        let minimum = String(string(editable["change_start"]).prefix(10))
        let maximum = String(string(editable["change_end"]).prefix(10))
        let allowed = truth(editable["is_editable"]) && (minimum.isEmpty || day >= minimum) && (maximum.isEmpty || day <= maximum)
        let scope = Set(shopNumbers)
        var slots: [[String: Any]] = []
        var anySelectedSlots = false
        var seenSlots = Set<String>()
        for date in free["items"] as? [[String: Any]] ?? [] where string(date["date"]) == day {
            let groups = (date["shops"] as? [[String: Any]] ?? []) + (date["clusters"] as? [[String: Any]] ?? [])
            for group in groups {
                let groupID = Int(string(group["shopno"] ?? group["shop_number"]))
                let nestedShops = group["shops"] as? [[String: Any]] ?? []
                let nestedIDs = Set(nestedShops.compactMap { Int(string($0["shopno"] ?? $0["shop_number"])) })
                let matches = scope.isEmpty || groupID.map(scope.contains) == true || !scope.isDisjoint(with: nestedIDs)
                guard matches else { continue }
                let entries = group["slots"] as? [[String: Any]] ?? []
                anySelectedSlots = anySelectedSlots || !entries.isEmpty
                for entry in entries where truth(entry["is_available"]) {
                    let id = string(entry["slot_id"] ?? entry["id"])
                    guard !id.isEmpty, seenSlots.insert(id).inserted else { continue }
                    var slot = entry
                    slot["slot_id"] = id
                    slot["shopno"] = entry["shopno"] ?? groupID
                    let name = string(group["shop_name"] ?? group["name"])
                    slot["shop_label"] = !name.isEmpty ? name : groupID.map { "Магазин №\($0)" } ?? "Интервал кластера"
                    slots.append(slot)
                }
            }
        }
        // A booking is tied to one explicitly selected store. Viewing can span all.
        var manual = allowed && shopNumbers.count == 1 && (!flags.contains(375) || !anySelectedSlots)
        if flags.contains(376) {
            let shops = try await dictionary(Self.scheduleRoot + "/me/schedules/shops?allow_manual_slots=true")
            manual = allowed && shopNumbers.count == 1 && (shops["items"] as? [[String: Any]] ?? []).contains { Int(string($0["shopno"])) == shopNumbers[0] }
        }
        return ScheduleData(editable: allowed, manual: manual, minDate: minimum, maxDate: maximum, slots: slots, assigned: assignedRows)
    }

    @discardableResult
    func book(day: String, start: String, end: String, slotID: String?) async throws -> ScheduleBookingResult {
        guard shopNumbers.count == 1, let shop = shopNumbers.first, shop > 0 else { throw CourierError(message: "Сначала выбери один магазин для записи в график.") }
        // Re-read eligibility and availability immediately before writing.
        let data = try await schedule(day: day)
        guard data.editable else { throw CourierError(message: "ВВ не разрешает запись на эту дату.") }
        var from = start, to = end
        var numericSlot: Int?
        if let slotID {
            guard let slot = data.slots.first(where: { string($0["slot_id"]) == slotID }), let id = Int(slotID) else { throw CourierError(message: "Интервал уже недоступен. Обнови график.") }
            numericSlot = id
            from = string(slot["time_from"] ?? slot["start"])
            to = string(slot["time_to"] ?? slot["end"])
        } else {
            guard data.manual else { throw CourierError(message: "На эту дату ВВ разрешает только свободные интервалы из списка.") }
            guard ScheduleTimes.starts.contains(start), ScheduleTimes.ends.contains(end) else {
                throw CourierError(message: "Выбери время из списка: шаг 30 минут, конец дня — 23:59.")
            }
        }
        guard let interval = scheduleInterval(day: day, start: from, end: to) else { throw CourierError(message: "Укажи корректные начало и окончание выхода. Они не должны совпадать.") }
        guard data.maxDate.isEmpty || moscowDay(interval.1) <= data.maxDate else { throw CourierError(message: "Выход заканчивается за пределами доступного графика.") }
        for entry in data.entries {
            guard let existing = entry.interval else {
                throw CourierError(message: "Не удалось проверить время одного из назначенных выходов. Обнови график перед записью.")
            }
            guard !(interval.0 < existing.1 && existing.0 < interval.1) else { throw CourierError(message: "Этот интервал пересекается с уже назначенным выходом.") }
        }
        let url = Self.scheduleRoot + (numericSlot == nil ? "/me/schedule" : "/me/schedules/limited-slots")
        let payload: [String: Any]
        if let numericSlot { payload = ["slot_ids": [numericSlot]] }
        else {
            // Wte() -> ste() in the official client sends HH:mm, never HH:mm:ss.
            payload = ["shopno": shop, "slots": [["date": day, "periods": [["time_from": scheduleTime(interval.0), "time_to": scheduleTime(interval.1)]]]]]
        }
        let response: [String: Any]
        do { response = try await dictionary(url, body: payload) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if let code = (error as? CourierError)?.statusCode, (400..<500).contains(code) { throw error }
            return try await verifyScheduleBooking(shopID: shop, day: day, start: from, end: to, acknowledged: false)
        }
        if numericSlot != nil {
            guard string(response["status"]) == "created" else { throw CourierError(message: string(response["message"]).isEmpty ? "ВВ отклонил запись на интервал. Обнови график." : string(response["message"])) }
        } else {
            guard response.isEmpty else { throw CourierError(message: string(response["message"]).isEmpty ? "ВВ не подтвердил запись. Обнови график." : string(response["message"])) }
        }
        return try await verifyScheduleBooking(shopID: shop, day: day, start: from, end: to, acknowledged: true)
    }

    private func verifyScheduleBooking(shopID: Int, day: String, start: String, end: String, acknowledged: Bool) async throws -> ScheduleBookingResult {
        do {
            let rows = try await scheduleAssignments()
            if scheduleContains(rows, shopID: shopID, day: day, start: start, end: end) {
                return ScheduleBookingResult(assignments: rows, acknowledged: acknowledged, readbackSucceeded: true, message: "ВВ подтвердил запись в графике.")
            }
            return ScheduleBookingResult(assignments: nil, acknowledged: acknowledged, readbackSucceeded: true, message: "В свежем графике выход пока не найден. Повторно запрос не отправлен. Проверь запись ещё раз перед повтором.")
        } catch is CancellationError { throw CancellationError() }
        catch {
            if (error as? CourierError)?.statusCode == 401 { throw error }
            return ScheduleBookingResult(assignments: nil, acknowledged: acknowledged, readbackSucceeded: false, message: acknowledged ? "ВВ принял запрос, но проверить запись в графике не удалось. Повторно запрос не отправлен." : "Ответ на запись не получен, её статус пока неизвестен. Повторно запрос не отправлен.")
        }
    }
}

func moscowDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private struct ScheduleBooking: Identifiable {
    let id = UUID()
    let day: String
    let start: String
    let end: String
    let shopID: Int
    let shopLabel: String
    let scope: String
    let owner: String
    let slotID: String?
    var intervalLabel: String {
        guard let interval = scheduleInterval(day: day, start: start, end: end) else { return start + " — " + end }
        return scheduleTime(interval.0) + " — " + scheduleTime(interval.1) + (moscowDay(interval.0) == moscowDay(interval.1) ? "" : " · следующий день")
    }
}

struct ScheduleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var date = Date()
    @State private var start = "08:00"
    @State private var end = "21:00"
    @State private var data: ScheduleData?
    @State private var booking: ScheduleBooking?
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var loadedKey: String?
    @State private var error: String?
    @State private var message: String?
    @State private var verification: ScheduleBooking?
    @State private var verificationCheckedAbsent = false
    @State private var bookingWarning: String?
    @State private var demoExits: [[String: Any]] = []
    private var requestKey: String { model.shopScopeKey + "/" + moscowDay(date) }
    private var selectedShop: Shop? { model.shops.first { $0.id == model.selectedShopID } }
    private var currentData: ScheduleData? { loadedKey == requestKey ? data : nil }
    private var displayedEntries: [ScheduleEntry] {
        (currentData?.entries ?? []).filter { model.selectedShopID == nil || $0.shopID == model.selectedShopID }
    }

    var body: some View {
        CourierPage("График смен", subtitle: "Запланированные выходы и свободные интервалы", artwork: 2) {
            if model.demo { DemoBanner() }
            ShopScopeButton()
            CourierCard {
                DatePicker("Дата", selection: $date, displayedComponents: .date).disabled(model.busy)
                Text("Все интервалы указаны по московскому времени.").font(.caption).foregroundStyle(Palette.muted)
            }
            if let message { CourierCard { Label(message, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(Palette.success) } }
            if let verification, verification.owner == model.identity {
                CourierCard {
                    Label("Проверка записи", systemImage: "clock.arrow.circlepath").font(.headline)
                    Text(displayDate(verification.day) + " · " + verification.intervalLabel + " · " + verification.shopLabel).font(.subheadline)
                    Text(bookingWarning ?? "Проверяю подтверждение ВВ…").font(.caption).foregroundStyle(Palette.warning)
                    Button("Проверить запись") { Task { await verifyBooking() } }.buttonStyle(CourierButtonStyle()).disabled(loading || model.busy).accessibilityIdentifier("schedule.verify")
                    if verificationCheckedAbsent {
                        Button("Выбрать интервал заново") { self.verification = nil; verificationCheckedAbsent = false; bookingWarning = nil }
                            .buttonStyle(CourierButtonStyle()).disabled(loading || model.busy).accessibilityIdentifier("schedule.retry-selection")
                    }
                }.accessibilityIdentifier("schedule.pending")
            }
            if loading { HStack(spacing: 10) { ProgressView(); Text("Обновляю график…").font(.caption).foregroundStyle(Palette.muted) } }
            if let error { CourierErrorCard(message: error) { Task { await load() } } }
            if let data = currentData {
                assignedCard
                if model.selectedShopID == nil {
                    CourierCard {
                        Text("Выбери магазин для записи").font(.headline)
                        Text("Просматривать график можно по всем магазинам. Чтобы назначить выход, сначала выбери один конкретный магазин выше.").font(.subheadline).foregroundStyle(Palette.muted)
                    }
                }
                freeSlotsCard(data)
                if data.manual && model.selectedShopID != nil { manualCard }
                if !data.editable {
                    CourierCard {
                        Label("Изменение графика недоступно", systemImage: "lock").font(.headline)
                        Text(boundsMessage(data)).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                } else if model.selectedShopID != nil && !data.manual && data.slots.isEmpty {
                    CourierEmpty(title: "Нет доступных интервалов", message: "ВВ пока не разрешает ручную запись на эту дату. Выбери другую дату или обнови график.", symbol: "calendar.badge.clock")
                }
            }
        }
        .navigationTitle("График смен").navigationBarTitleDisplayMode(.inline)
        .environment(\.timeZone, TimeZone(identifier: "Europe/Moscow")!)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading || model.busy).accessibilityLabel("Обновить график")
            }
        }
        .task(id: requestKey) { await load() }
        .refreshable { await load() }
        .confirmationDialog(bookingTitle, isPresented: Binding(get: { booking != nil }, set: { if !$0 { booking = nil } }), titleVisibility: .visible) {
            Button("Подтвердить запись") { confirmBooking() }
        } message: { Text(bookingDescription) }
    }

    private var assignedCard: some View {
        CourierCard("Назначенные выходы") {
            if displayedEntries.isEmpty {
                Text(model.selectedShopID == nil ? "Назначенных выходов пока нет." : "В выбранном магазине пока нет назначенных выходов.").font(.subheadline).foregroundStyle(Palette.muted)
            } else {
                ForEach(displayedEntries) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(displayDate(entry.day)).font(.subheadline.weight(.semibold)); Spacer(); Image(systemName: "calendar.badge.checkmark").foregroundStyle(Palette.muted) }
                        Text(entry.timeLabel).font(.headline).monospacedDigit()
                        Text(entry.shopLabel).font(.caption).foregroundStyle(Palette.muted)
                    }.padding(.vertical, 5)
                    if entry.id != displayedEntries.last?.id { Divider().overlay(Palette.line) }
                }
            }
        }
    }

    private func freeSlotsCard(_ data: ScheduleData) -> some View {
        CourierCard("Свободные интервалы · \(displayDate(moscowDay(date)))") {
            if data.slots.isEmpty {
                Text("Свободных интервалов на эту дату нет.").font(.subheadline).foregroundStyle(Palette.muted)
            } else {
                ForEach(data.slots.indices, id: \.self) { index in
                    let slot = data.slots[index]
                    let from = string(slot["time_from"] ?? slot["start"])
                    let to = string(slot["time_to"] ?? slot["end"])
                    VStack(alignment: .leading, spacing: 10) {
                        Text(slotLabel(day: moscowDay(date), start: from, end: to)).font(.headline).monospacedDigit()
                        Text(string(slot["shop_label"])).font(.caption).foregroundStyle(Palette.muted)
                        Button("Выбрать интервал") { prepareBooking(start: from, end: to, slotID: string(slot["slot_id"])) }
                            .buttonStyle(CourierButtonStyle()).disabled(!data.editable || model.selectedShopID == nil || model.busy || loading || verification != nil)
                    }.padding(.vertical, 4)
                    if index < data.slots.count - 1 { Divider().overlay(Palette.line) }
                }
            }
        }
    }

    private var manualCard: some View {
        CourierCard("Свой интервал") {
            Picker("Начало", selection: $start) { ForEach(ScheduleTimes.starts, id: \.self) { Text($0).tag($0) } }.disabled(model.busy).accessibilityIdentifier("schedule.start")
            Picker("Окончание", selection: $end) { ForEach(ScheduleTimes.ends, id: \.self) { Text($0).tag($0) } }.disabled(model.busy).accessibilityIdentifier("schedule.end")
            if end < start { Text("Окончание — на следующий день.").font(.caption).foregroundStyle(Palette.muted) }
            Button("Записаться в график") { prepareBooking(start: start, end: end, slotID: nil) }
                .buttonStyle(CourierButtonStyle(primary: true)).disabled(model.busy || loading || start == end || verification != nil).accessibilityIdentifier("schedule.book")
        }
    }

    @MainActor private func load() async {
        let currentID = UUID(), key = requestKey, day = moscowDay(date)
        let api = model.api
        let isDemo = model.demo
        loadID = currentID; loading = true; data = nil; loadedKey = nil; error = nil; booking = nil; message = nil
        defer { if loadID == currentID { loading = false } }
        do {
            let result: ScheduleData
            if isDemo {
                let shop = model.selectedShopID
                let slots: [[String: Any]] = shop.map { id in [["slot_id": "demo-\(id)", "time_from": "10:00:00", "time_to": "14:00:00", "shopno": id, "shop_label": selectedShop?.title ?? "Демонстрационный магазин"]] } ?? []
                result = ScheduleData(editable: true, manual: shop != nil, minDate: "", maxDate: "", slots: slots, assigned: demoExits)
            } else { result = try await api.schedule(day: day) }
            guard !Task.isCancelled, loadID == currentID, requestKey == key else { return }
            data = result; loadedKey = key
            if let intent = verification, intent.owner == model.identity {
                applyVerification(rows: result.assigned, intent: intent)
            }
        } catch {
            guard !Task.isCancelled, loadID == currentID, requestKey == key else { return }
            self.error = error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }

    private func prepareBooking(start: String, end: String, slotID: String?) {
        guard let shopID = model.selectedShopID, let data = currentData, data.editable, scheduleInterval(day: moscowDay(date), start: start, end: end) != nil else {
            model.error = "Выбери магазин и доступный интервал."; return
        }
        guard slotID != nil || data.manual else { model.error = "ВВ не разрешает ручную запись на эту дату."; return }
        booking = ScheduleBooking(day: moscowDay(date), start: start, end: end, shopID: shopID, shopLabel: selectedShop?.title ?? "Магазин №\(shopID)", scope: model.shopScopeKey, owner: model.identity, slotID: slotID)
    }

    private func confirmBooking() {
        guard let intent = booking else { return }
        booking = nil
        guard model.selectedShopID == intent.shopID, model.shopScopeKey == intent.scope, moscowDay(date) == intent.day else {
            model.error = "Магазин или дата изменились. Выбери интервал заново."; return
        }
        var api = model.api
        api.shopNumbers = [intent.shopID]
        let demo = model.demo
        model.perform {
            guard model.shopScopeKey == intent.scope, !Task.isCancelled else { return }
            if demo {
                let row: [String: Any] = ["date": intent.day, "slots": [["id": UUID().uuidString, "shopno": intent.shopID, "shop_name": intent.shopLabel, "time_from": intent.start, "time_to": intent.end]]]
                demoExits.append(row)
                await load()
                guard model.shopScopeKey == intent.scope, !Task.isCancelled else { return }
                message = "Демо: выход добавлен локально. В ВВ ничего не отправлено."
            } else {
                verification = intent; verificationCheckedAbsent = false; bookingWarning = nil; message = nil
                do {
                    let result = try await api.book(day: intent.day, start: intent.start, end: intent.end, slotID: intent.slotID)
                    guard model.identity == intent.owner, model.shopScopeKey == intent.scope, !Task.isCancelled else { return }
                    if let rows = result.assignments { applyVerification(rows: rows, intent: intent) }
                    else { bookingWarning = result.message; verificationCheckedAbsent = result.readbackSucceeded }
                } catch {
                    guard model.identity == intent.owner, !Task.isCancelled else { return }
                    verification = nil; bookingWarning = nil; verificationCheckedAbsent = false
                    throw error
                }
            }
        }
    }

    @MainActor private func verifyBooking() async {
        guard let intent = verification, intent.owner == model.identity, !loading, !model.busy else { return }
        let owner = model.identity, api = model.api
        loading = true; defer { if model.identity == owner { loading = false } }
        do {
            let rows = try await api.scheduleAssignments()
            guard model.identity == owner, verification?.id == intent.id, !Task.isCancelled else { return }
            applyVerification(rows: rows, intent: intent)
        } catch {
            guard model.identity == owner, verification?.id == intent.id, !Task.isCancelled else { return }
            bookingWarning = "Проверить запись пока не удалось. Повторная запись не отправлялась. " + error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }

    @MainActor private func applyVerification(rows: [[String: Any]], intent: ScheduleBooking) {
        guard intent.owner == model.identity else { return }
        if let current = data {
            data = ScheduleData(editable: current.editable, manual: current.manual, minDate: current.minDate, maxDate: current.maxDate,
                                slots: current.slots.filter { intent.slotID == nil || string($0["slot_id"]) != intent.slotID }, assigned: rows)
        }
        if scheduleContains(rows, shopID: intent.shopID, day: intent.day, start: intent.start, end: intent.end) {
            verification = nil; verificationCheckedAbsent = false; bookingWarning = nil
            message = "Запись подтверждена в графике ВВ: " + displayDate(intent.day) + " · " + intent.intervalLabel + "."
        } else {
            verificationCheckedAbsent = true
            bookingWarning = "В свежем графике выход пока не найден. Можно проверить ещё раз или выбрать интервал заново; повторная запись сама не отправляется."
        }
    }

    private var bookingTitle: String { booking.map { "Записаться в \($0.shopLabel)?" } ?? "Подтвердить запись?" }
    private var bookingDescription: String { booking.map { displayDate($0.day) + " · " + $0.intervalLabel + "\nВремя московское." } ?? "" }
    private func slotLabel(day: String, start: String, end: String) -> String {
        guard let interval = scheduleInterval(day: day, start: start, end: end) else { return start + " — " + end }
        return scheduleTime(interval.0) + " — " + scheduleTime(interval.1) + (moscowDay(interval.0) == moscowDay(interval.1) ? "" : " · следующий день")
    }
    private func displayDate(_ day: String) -> String {
        guard let date = timestamp(day + "T00:00:00") else { return day }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.timeZone = TimeZone(identifier: "Europe/Moscow"); formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }
    private func boundsMessage(_ data: ScheduleData) -> String {
        if !data.minDate.isEmpty && !data.maxDate.isEmpty { return "ВВ разрешает менять график с \(displayDate(data.minDate)) по \(displayDate(data.maxDate)). Назначенные выходы доступны для просмотра." }
        return "ВВ не разрешает изменение на выбранную дату. Назначенные выходы доступны для просмотра."
    }
}
