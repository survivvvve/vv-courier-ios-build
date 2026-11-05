import SwiftUI
import UIKit

struct DayTotal: Codable {
    var day: String
    var gross = 0.0
    var count = 0
    var weight = 0.0
    var late = 0
    var minutes = 0
    var idle = 0
    var fetchedAt: Date? = nil
    var timedCount: Int? = nil
    var weightedCount: Int? = nil
    var firstDelivery: Date? = nil
    var lastDelivery: Date? = nil

    var net: Double { gross * 0.94 }
    var tax: Double { gross * 0.06 }
    var hours: Double { Double(minutes) / 60 }
    var average: Double? { count > 0 ? gross / Double(count) : nil }
    var hourly: Double? { guard hours > 0 else { return nil }; let value = net / hours; return value.isFinite ? value : nil }
    var grossHourly: Double? { guard hours > 0 else { return nil }; let value = gross / hours; return value.isFinite ? value : nil }
    var ordersPerHour: Double? { hours > 0 ? Double(count) / hours : nil }
    var duration: String { minutes > 0 ? "\(minutes / 60) ч \(minutes % 60) мин" : "—" }
    var idleDuration: String { idle > 0 ? "\(idle / 60) ч \(idle % 60) мин" : "нет" }
    var hasPartialWeight: Bool { weightedCount.map { $0 < count } ?? false }
    var totalWeightText: String {
        guard weight.isFinite, weight >= 0 else { return "—" }
        if count > 0 && (weightedCount == 0 || (weightedCount == nil && weight == 0)) { return "—" }
        return String(format: "%.3f", weight).replacingOccurrences(of: ".", with: ",") + " кг"
    }
    var timeRange: String? {
        guard let firstDelivery, let lastDelivery else { return nil }
        return Self.clock.string(from: firstDelivery) + " — " + Self.clock.string(from: lastDelivery)
    }
    mutating func include(_ item: DayTotal) {
        let previousCount = count
        gross += item.gross; count += item.count
        weight += item.weight; late += item.late
        minutes += item.minutes; idle += item.idle
        timedCount = (timedCount ?? previousCount) + (item.timedCount ?? item.count)
        if let known = weightedCount, let added = item.weightedCount { weightedCount = known + added }
        else { weightedCount = nil }
        if let first = item.firstDelivery { firstDelivery = firstDelivery.map { min($0, first) } ?? first }
        if let last = item.lastDelivery { lastDelivery = lastDelivery.map { max($0, last) } ?? last }
    }
    private static let clock: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "ru_RU")
        value.timeZone = TimeZone(identifier: "Europe/Moscow")!
        value.dateFormat = "HH:mm"
        return value
    }()
}

extension CourierAPI {
    func dayTotal(offset daysAgo: Int, relativeTo now: Date = Date()) async throws -> DayTotal {
        guard (0...2).contains(daysAgo) else { throw CourierError(message: "ВВ показывает архив только за последние три дня.") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        guard let selected = calendar.date(byAdding: .day, value: -daysAgo, to: now) else {
            throw CourierError(message: "Не удалось определить дату отчёта.")
        }
        let start = calendar.startOfDay(for: selected)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-0.001)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result = DayTotal(day: moscowDay(start))
        result.weightedCount = 0
        var dates: [Date] = []
        var pagination = CourierPagination(limit: 25, maximum: 100_000)
        var archivedGross: Double?
        while true {
            try Task.checkCancellation()
            let payload: [String: Any] = [
                "id_courier": session?.courierID ?? "",
                "pagination": ["offset": pagination.offset, "limit": pagination.limit],
                "date_time_start": formatter.string(from: start),
                "date_time_end": formatter.string(from: end)
            ]
            let data = try await dictionary(Self.root + "/v1/courier/get_parcels_archive", body: payload)
            try Task.checkCancellation()
            guard let rows = data["parcels"] as? [[String: Any]] else {
                throw CourierError(message: "ВВ вернул неизвестный формат архива. Сохранённый итог не изменён.")
            }
            if let value = data["courier_profit_sum"], !(value is NSNull), archivedGross == nil {
                guard let valid = incomeAmount(value) else { throw CourierError(message: "ВВ вернул некорректную сумму дохода. Итог не сохранён.") }
                archivedGross = valid
            }
            let page = try pagination.consume(rows, reportedTotal: data["total"], idKeys: ["id_parcel", "id_general_view"])
            for row in page.rows {
                result.count += 1
                let rawReward = row["courier_profit_sum"] ?? row["reward"]
                if let rawReward {
                    guard let reward = incomeAmount(rawReward) else { throw CourierError(message: "ВВ вернул некорректное вознаграждение. Итог не сохранён.") }
                    result.gross += reward
                } else if archivedGross == nil { throw CourierError(message: "ВВ не сообщил вознаграждение одного из заказов. Итог не сохранён.") }
                if let weight = finiteNumber(row["weight"]), weight >= 0 {
                    result.weight += weight
                    result.weightedCount = (result.weightedCount ?? 0) + 1
                }
                if let value = row["time_until_delay_seconds"] ?? row["route_time_until_delay"] ?? row["time_until_delay"], number(value) < 0 {
                    result.late += 1
                }
                // Archive delivery time takes precedence over later record edits.
                let delivered = ["delivered_at", "date_delivered", "updated_at"].compactMap { timestamp(row[$0]) }.first
                if let delivered, delivered >= start && delivered <= end { dates.append(delivered) }
            }
            if page.complete { break }
        }
        dates.sort()
        result.timedCount = dates.count
        result.firstDelivery = dates.first
        result.lastDelivery = dates.last
        if let first = dates.first, let last = dates.last, dates.count > 1, last > first {
            let elapsed = last.timeIntervalSince(first)
            var idleSeconds = 0.0
            for (previous, following) in zip(dates, dates.dropFirst()) {
                let gap = following.timeIntervalSince(previous)
                if gap > 7200 { idleSeconds += gap - 1200 }
                else if gap > 5400 { idleSeconds += gap }
            }
            result.idle = Int(idleSeconds / 60)
            result.minutes = max(0, Int((elapsed - idleSeconds) / 60))
        }
        if let archivedGross { result.gross = archivedGross }
        guard result.gross.isFinite, result.gross >= 0 else {
            throw CourierError(message: "ВВ вернул некорректную сумму. Итог не сохранён.")
        }
        result.fetchedAt = Date()
        try Task.checkCancellation()
        let key = "day.\(session?.courierID ?? "guest").\(result.day)"
        UserDefaults.standard.set(try JSONEncoder().encode(result), forKey: key)
        return result
    }

    func cachedDay(_ day: String) -> DayTotal? {
        guard let data = UserDefaults.standard.data(forKey: "day.\(session?.courierID ?? "guest").\(day)") else { return nil }
        guard let item = try? JSONDecoder().decode(DayTotal.self, from: data), item.day == day, item.gross.isFinite, item.gross >= 0, item.weight.isFinite, item.weight >= 0, item.count >= 0, item.late >= 0, item.late <= item.count, item.minutes >= 0, item.idle >= 0,
              item.weightedCount.map({ (0...item.count).contains($0) }) ?? true else { return nil }
        return item
    }
}

// Missing or malformed currency must not silently become zero in a saved report.
private func incomeAmount(_ raw: Any?) -> Double? {
    finiteNumber(raw)
}

private enum IncomePeriod: Int, CaseIterable, Identifiable {
    case today = 0, yesterday = 1, beforeYesterday = 2, three = 3, five = 5, week = 7
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .today: return "Сегодня"
        case .yesterday: return "Вчера"
        case .beforeYesterday: return "Позавчера"
        case .three: return "3 дня"
        case .five: return "5 дней"
        case .week: return "Неделя"
        }
    }
    var offsets: [Int] { rawValue >= 3 ? Array(0..<rawValue) : [rawValue] }
    func dateLabel(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMMM"
        let oldest = calendar.date(byAdding: .day, value: -(offsets.last ?? 0), to: now)!
        if offsets.count == 1 { return formatter.string(from: oldest) }
        return formatter.string(from: oldest) + " — " + formatter.string(from: now)
    }
}

private struct IncomeExport: Identifiable {
    let id = UUID()
    let url: URL
    let width: Int
    let height: Int
}

struct IncomeView: View {
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var rides = WheelRideStore.shared
    @State private var selection = IncomePeriod.today
    @State private var total: DayTotal?
    @State private var notice = ""
    @State private var error: String?
    @State private var loading = false
    @State private var receipts: [(String, String)] = []
    @State private var receiptError: String?
    @State private var receiptLoaded = false
    @State private var receiptsOpen = false
    @State private var receiptIdentity = ""
    @State private var loadID = UUID()
    @State private var export: IncomeExport?
    @State private var exportStatus: String?
    @State private var reportDays: [String] = []
    @State private var reportLabel = ""
    @State private var receiptFetchedDay = ""
    @State private var loadedIncomeDays: Set<String> = []
    @State private var savedIncomeDays: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var requestKey: String { model.identity + "/" + moscowDay(Date()) + "/\(selection.rawValue)" }
    private var riding: WheelRideSummary { rides.summary(courierID: model.demo ? "demo" : model.session?.courierID ?? "guest", days: reportDays) }
    private var incomeComplete: Bool { !reportDays.isEmpty && reportDays.allSatisfy { loadedIncomeDays.contains($0) } }
    private var posterDayCount: Int { loadedIncomeDays.count }
    private var posterCoverage: String {
        guard !model.demo else { return "" }
        var parts: [String] = []
        if posterDayCount < reportDays.count { parts.append("ДАННЫЕ ЗА \(posterDayCount) ИЗ \(reportDays.count) ДНЕЙ") }
        if !savedIncomeDays.isEmpty { parts.append("СОХРАНЁННЫЕ ДАННЫЕ") }
        if let total, total.hasPartialWeight, let count = total.weightedCount { parts.append("ВЕС ИЗВЕСТЕН ДЛЯ \(count) ИЗ \(total.count) ЗАКАЗОВ") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            CourierPage("Итоги заработка", subtitle: "Доставки по всем магазинам", artwork: 4) {
                if model.demo { DemoBanner() }
                periodPicker
                if loading {
                    HStack(spacing: 10) { ProgressView(); Text("Обновляю архив…").font(.caption).foregroundStyle(Palette.muted) }
                }
                if let error { CourierErrorCard(message: error) { Task { await load(forceReceipts: true) } } }
                if let total {
                    IncomePosterPreview(total: total, period: reportLabel, dayCount: posterDayCount, coverage: posterCoverage, demo: model.demo)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button { exportReport(total) } label: { Label("Сохранить или отправить", systemImage: "square.and.arrow.up") }
                        .buttonStyle(CourierButtonStyle(primary: true))
                        .accessibilityLabel("Сохранить или отправить карточку")
                        .accessibilityIdentifier("income.share")
                    if let exportStatus { Text(exportStatus).font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("income.export.status") }
                    IncomeSummaryCard(total: total, period: reportLabel, notice: notice, demo: model.demo, riding: riding, ridingDayCount: reportDays.count, ridingIncomeComplete: incomeComplete)
                        .accessibilityIdentifier("income.summary")
                } else if !loading && error == nil {
                    CourierEmpty(title: "История ещё не загружена", message: "Обнови архив, чтобы увидеть итог за выбранный период.", symbol: "chart.bar.xaxis")
                }
                if total == nil && !loading {
                    CourierCard { RideIncomeReport(summary: riding, netIncome: nil, dayCount: reportDays.count, demo: model.demo) }
                }
                receiptsCard
                CourierCard {
                    Label("Как считается доход", systemImage: "info.circle").font(.subheadline.weight(.semibold))
                    Text("После налога — сумма за вычетом 6%. Время оценивается между первой и последней доставкой за каждый день. Перерывы больше 90 минут исключаются; для перерывов больше двух часов остаётся по 10 минут с каждой стороны.")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text("Почасовые значения — расчётная оценка, а не табель смены. Более старые дни доступны, если их итоги ранее сохранились на этом iPhone.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
            .courierBrandHeader()
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) { Button("Готово", action: onClose).accessibilityIdentifier("original.income.close") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load(forceReceipts: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading).accessibilityLabel("Обновить доходы")
                }
            }
            .task(id: requestKey) { await load() }
            .refreshable { await load(forceReceipts: true) }
            .sheet(item: $export) { item in IncomeShareSheet(url: item.url, width: item.width, height: item.height).presentationDetents([.medium, .large]) }
        }
    }

    private var periodPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(IncomePeriod.allCases) { period in
                Button { selection = period } label: { Text(period.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8) }
                    .buttonStyle(CourierButtonStyle(primary: selection == period))
                    .accessibilityAddTraits(selection == period ? .isSelected : [])
                    .accessibilityIdentifier("income.period.\(period.rawValue)")
            }
        }
    }

    private var receiptsCard: some View {
        CourierCard {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { receiptsOpen.toggle() }
            } label: {
                HStack {
                    Image(systemName: "doc.text")
                    Text("Чеки доходов").font(.headline)
                    Spacer()
                    if receiptLoaded { Text("\(receipts.count)").font(.caption).foregroundStyle(Palette.muted) }
                    Image(systemName: "chevron.down").rotationEffect(.degrees(receiptsOpen ? 180 : 0)).font(.caption)
                }
            }.buttonStyle(.plain).accessibilityLabel(receiptsOpen ? "Скрыть чеки" : "Показать чеки")
            if receiptsOpen {
                if let receiptError {
                    Text(receiptError).font(.caption).foregroundStyle(Palette.warning)
                    Button("Повторить загрузку") { Task { await load(forceReceipts: true) } }.buttonStyle(CourierButtonStyle()).disabled(loading)
                } else if !receiptLoaded {
                    Text("Чеки загружаются вместе с архивом.").font(.caption).foregroundStyle(Palette.muted)
                } else if receipts.isEmpty {
                    Text("ВВ пока не вернул чеков дохода.").font(.subheadline).foregroundStyle(Palette.muted)
                } else {
                    ForEach(receipts.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline) {
                            Text(receiptDate(receipts[index].0)).font(.subheadline).foregroundStyle(Palette.muted)
                            Spacer()
                            Text(receipts[index].1).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }.padding(.vertical, 5)
                        if index < receipts.count - 1 { Divider().overlay(Palette.line) }
                    }
                }
            }
        }
    }

    @MainActor private func load(forceReceipts: Bool = false) async {
        let currentID = UUID()
        let period = selection
        let api = model.api
        let identity = model.identity
        let isDemo = model.demo
        if receiptIdentity != identity {
            receiptIdentity = identity; receipts = []; receiptLoaded = false; receiptError = nil; receiptsOpen = false; receiptFetchedDay = ""
        }
        loadID = currentID
        loading = true
        total = nil; notice = ""; error = nil; exportStatus = nil
        loadedIncomeDays = []; savedIncomeDays = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let reportDate = Date()
        let days = period.offsets.map { moscowDay(calendar.date(byAdding: .day, value: -$0, to: reportDate)!) }
        reportDays = days
        let label = period.dateLabel(now: reportDate)
        reportLabel = label
        defer { if loadID == currentID { loading = false } }
        if isDemo {
            let count = period.offsets.count
            let first = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: reportDate)!
            total = DayTotal(day: count == 1 ? days[0] : label, gross: 2711.65 * Double(count), count: 18 * count, weight: 72.323 * Double(count), late: 2 * count, minutes: 115 * count, idle: 95 * count, fetchedAt: Date(), timedCount: 18 * count, weightedCount: 18 * count, firstDelivery: first, lastDelivery: first.addingTimeInterval(210 * 60))
            loadedIncomeDays = Set(days)
            notice = "Демо: вымышленные суммы и доставки."
            receipts = [("Демо-чек", "2 711,65 ₽")]; receiptLoaded = true; receiptError = nil
            return
        }
        guard model.session != nil else {
            error = "Войди в аккаунт ВВ, чтобы загрузить архив. После входа итоги обновятся автоматически."
            return
        }
        var aggregate = DayTotal(day: days.count == 1 ? days[0] : label, timedCount: 0, weightedCount: 0)
        var loadedDays = 0
        var missing: [String] = []
        var saved: [String] = []
        for (offset, day) in zip(period.offsets, days) {
            guard !Task.isCancelled, loadID == currentID, model.identity == identity else { return }
            var item: DayTotal?
            if offset < 3 {
                do { item = try await api.dayTotal(offset: offset, relativeTo: reportDate) }
                catch {
                    guard !Task.isCancelled, loadID == currentID, model.identity == identity else { return }
                    item = api.cachedDay(day)
                    if item != nil { saved.append(day); savedIncomeDays.insert(day) }
                    else if period.offsets.count == 1 { self.error = error.localizedDescription }
                }
            } else { item = api.cachedDay(day) }
            guard !Task.isCancelled, loadID == currentID, model.identity == identity else { return }
            if let item {
                loadedDays += 1
                loadedIncomeDays.insert(day)
                aggregate.include(item)
            } else { missing.append(shortDate(day)) }
        }
        guard !Task.isCancelled, loadID == currentID, model.identity == identity else { return }
        let timed = aggregate.timedCount ?? 0
        aggregate.fetchedAt = Date()
        var notes: [String] = []
        if loadedDays > 0 { total = aggregate }
        if !missing.isEmpty { notes.append("Данные за \(loadedDays) из \(period.offsets.count) дней. Нет истории за \(missing.joined(separator: ", ")).") }
        if !saved.isEmpty { notes.append("Архив ВВ сейчас не обновился: использован сохранённый итог за \(saved.map(shortDate).joined(separator: ", ")).") }
        if timed < aggregate.count { notes.append("У части доставок нет времени завершения: почасовая оценка может быть неполной.") }
        if aggregate.hasPartialWeight, let count = aggregate.weightedCount { notes.append("ВВ сообщил вес для \(count) из \(aggregate.count) заказов. Показана сумма только известных значений.") }
        if aggregate.count > 0 && aggregate.minutes == 0 { notes.append("Для расчёта времени и дохода в час нужны минимум две доставки с разным временем.") }
        notice = notes.joined(separator: " ")
        if !receiptLoaded || forceReceipts || receiptFetchedDay != moscowDay(reportDate) {
            do {
                let items = try await api.incomes()
                guard !Task.isCancelled, loadID == currentID, model.identity == identity else { return }
                receipts = items; receiptLoaded = true; receiptError = nil; receiptFetchedDay = moscowDay(reportDate)
            } catch {
                guard !Task.isCancelled, loadID == currentID, model.identity == identity else { return }
                receiptError = "Не удалось обновить чеки: \(error.localizedDescription)"
            }
        }
    }

    @MainActor private func exportReport(_ total: DayTotal) {
        let content = IncomePosterCanvas(total: total, period: reportLabel, dayCount: posterDayCount, coverage: posterCoverage, demo: model.demo)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.uiImage, let data = image.pngData() else {
            model.error = "Не удалось создать изображение итога."; return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("VV-Courier-income-\(selection.rawValue).png")
            try data.write(to: url, options: [.atomic])
            let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
            let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
            exportStatus = "Карточка готова · \(width)×\(height)"
            export = IncomeExport(url: url, width: width, height: height)
        } catch { model.error = "Не удалось сохранить изображение итога: \(error.localizedDescription)" }
    }

    private func shortDate(_ iso: String) -> String {
        let components = iso.split(separator: "-")
        guard components.count == 3 else { return iso }
        return "\(components[2]).\(components[1])"
    }
    private func receiptDate(_ raw: String) -> String {
        let parts = raw.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), (1...12).contains(month) else { return raw }
        return shortDate(raw) + "." + parts[0]
    }
}

private struct IncomeSummaryCard: View {
    let total: DayTotal
    let period: String
    let notice: String
    let demo: Bool
    let riding: WheelRideSummary
    let ridingDayCount: Int
    let ridingIncomeComplete: Bool
    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label(demo ? "ДЕМО · ИТОГ" : "ИТОГ ДОСТАВОК", systemImage: "chart.bar.xaxis").font(.system(size: 10, weight: .semibold)).tracking(1.2)
                Spacer()
            }.foregroundStyle(Palette.muted)
            Text(period).font(.subheadline).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 7) {
                Text(money(total.net)).font(.system(size: 39, weight: .semibold, design: .rounded)).monospacedDigit().tracking(-1.2).minimumScaleFactor(0.6).lineLimit(1)
                Text("после налога 6%").font(.caption).foregroundStyle(Palette.muted)
            }
            HStack {
                Text("До налога").foregroundStyle(Palette.muted)
                Spacer(); Text(money(total.gross)).monospacedDigit()
            }.font(.subheadline)
            Divider().overlay(Palette.line)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                CourierMetric(title: "На работе · оценка", value: total.duration, symbol: "clock")
                CourierMetric(title: "Доставок", value: String(total.count), symbol: "shippingbox")
                CourierMetric(title: "После налога в час", value: total.hourly.map(money) ?? "—", symbol: "chart.line.uptrend.xyaxis")
                CourierMetric(title: "Средний заказ", value: total.average.map(money) ?? "—", symbol: "banknote")
                CourierMetric(title: "Общий вес", value: total.totalWeightText, symbol: "scalemass")
                    .accessibilityIdentifier("income.weight")
                CourierMetric(title: "Просроки", value: String(total.late), symbol: "exclamationmark.circle")
                    .accessibilityIdentifier("income.late")
            }
            HStack {
                Text("Налог · \(money(total.tax))")
                Spacer()
                if let rate = total.ordersPerHour { Text("\(rate, specifier: "%.1f") заказа/ч") }
            }.font(.caption).foregroundStyle(Palette.muted)
            if total.idle > 0 {
                Label("Простой исключён · \(total.idle / 60) ч \(total.idle % 60) мин", systemImage: "pause.circle").font(.caption).foregroundStyle(Palette.muted)
            }
            if total.count == 0 {
                Text("В доступном архиве за этот период нет завершённых доставок.").font(.subheadline).foregroundStyle(Palette.muted)
            }
            if !notice.isEmpty {
                Text(notice).font(.caption).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Palette.line)
            RideIncomeReport(summary: riding, netIncome: ridingIncomeComplete ? total.net : nil, dayCount: ridingDayCount, demo: demo)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.line, lineWidth: 0.7))
    }
}

private struct IncomeShareSheet: UIViewControllerRepresentable {
    let url: URL
    let width: Int
    let height: Int
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "income.share.sheet"
        controller.view.accessibilityValue = "PNG \(width)×\(height)"
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
