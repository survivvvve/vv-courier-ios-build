import SwiftUI
import UIKit

/// The exported image is always 1200 × 630, independent of the phone's screen.
struct IncomePosterCanvas: View {
    let total: DayTotal
    let period: String
    let dayCount: Int
    var coverage: String = ""
    var demo: Bool = false

    private let ink = Color(red: 0.27, green: 0.17, blue: 0.31)
    private let muted = Color(red: 0.43, green: 0.33, blue: 0.46)
    private let rule = Color(red: 0.77, green: 0.68, blue: 0.79)
    private var hasData: Bool { dayCount > 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.white.opacity(0.81))
                .overlay {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(.white.opacity(0.75), lineWidth: 2)
                }
                .shadow(color: ink.opacity(0.12), radius: 24, x: 0, y: 9)
                .frame(width: 1120, height: 590)
                .offset(x: 40, y: 20)

            HStack(alignment: .firstTextBaseline, spacing: 22) {
                Text("ВКУСВИЛЛ  ·  \(headerTitle)")
                    .font(.system(size: 19, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 12)
                Text(headerRange)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(muted)
                    .lineLimit(1)
            }
            .frame(width: 1012, alignment: .leading)
            .offset(x: 96, y: 51)

            Text(statusLine)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(muted)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(width: 1012, height: 38, alignment: .topLeading)
                .offset(x: 96, y: 81)

            Text("ЗАРАБОТАНО")
                .font(.system(size: 19, weight: .bold))
                .tracking(2)
                .foregroundStyle(muted)
                .offset(x: 96, y: 128)

            Text(amount(total.gross))
                .font(.system(size: 116, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 1020, height: 140, alignment: .leading)
                .offset(x: 90, y: 166)

            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text("После налога 6%  ·  \(amount(total.net))")
                    .font(.system(size: 26, weight: .medium))
                Spacer(minLength: 12)
                Text("Налог: \(amount(total.tax))")
                    .font(.system(size: 20, weight: .medium))
            }
            .foregroundStyle(muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 1008, alignment: .leading)
            .offset(x: 100, y: 326)

            Rectangle()
                .fill(rule.opacity(0.55))
                .frame(width: 1012, height: 2)
                .offset(x: 94, y: 412)

            metric(amount(total.grossHourly), title: "В ЧАС · ДО НАЛОГА", symbol: "chart.line.uptrend.xyaxis")
                .offset(x: 98, y: 435)
            metric(hasData ? total.duration : "—", title: "АКТИВНОЕ ВРЕМЯ", symbol: "clock")
                .offset(x: 450, y: 435)
            metric(hasData ? String(total.count) : "—", title: "ЗАКАЗОВ", symbol: "shippingbox")
                .offset(x: 800, y: 435)

            ForEach([402.0, 754.0], id: \.self) { x in
                Rectangle()
                    .fill(rule.opacity(0.5))
                    .frame(width: 1, height: 87)
                    .offset(x: x, y: 431)
            }

            Text("После налога: \(amount(total.hourly))/ч")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 300, alignment: .leading)
                .offset(x: 98, y: 514)

            Label("Просроки: \(hasData ? String(total.late) : "—")", systemImage: "exclamationmark.circle")
                .font(.system(size: 17, weight: .semibold))
                .offset(x: 98, y: 543)

            Text(detailLine)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 1010, alignment: .leading)
                .offset(x: 98, y: 574)
        }
        .foregroundStyle(ink)
        .frame(width: 1200, height: 630)
        .clipped()
        .environment(\.colorScheme, .light)
        .dynamicTypeSize(.large)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("income.poster")
        .accessibilityLabel(accessibilitySummary)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.88, blue: 0.92), Color(red: 0.88, green: 0.83, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = IncomePosterAsset.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1200, height: 630)
                    .clipped()
            }
        }
        .frame(width: 1200, height: 630)
        .accessibilityHidden(true)
    }

    private func metric(_ value: String, title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: 42, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(height: 48, alignment: .leading)
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: 300, alignment: .leading)
    }

    private func amount(_ value: Double?) -> String {
        guard hasData, let value, value.isFinite, value >= 0 else { return "—" }
        return money(value)
    }

    private var headerTitle: String {
        guard dayCount == 1 else { return period.uppercased() }
        let source = DateFormatter()
        source.locale = Locale(identifier: "en_US_POSIX")
        source.timeZone = TimeZone(identifier: "Europe/Moscow")
        source.dateFormat = "yyyy-MM-dd"
        let display = DateFormatter()
        display.locale = Locale(identifier: "ru_RU")
        display.timeZone = source.timeZone
        display.dateFormat = "d MMMM yyyy"
        return source.date(from: total.day).map { display.string(from: $0).uppercased() } ?? period.uppercased()
    }

    private var headerRange: String {
        if dayCount == 1 { return total.timeRange ?? "" }
        return dayCount > 0 ? "\(dayCount) \(dayWord) с данными" : ""
    }

    private var dayWord: String {
        if dayCount % 10 == 1 && dayCount % 100 != 11 { return "день" }
        if (2...4).contains(dayCount % 10) && !(12...14).contains(dayCount % 100) { return "дня" }
        return "дней"
    }

    private var statusLine: String {
        var parts: [String] = []
        if demo { parts.append("ДЕМОНСТРАЦИЯ · ВЫМЫШЛЕННЫЕ ДАННЫЕ") }
        if !hasData { parts.append("НЕТ ДАННЫХ ЗА ПЕРИОД") }
        let note = coverage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var detailLine: String {
        let rate = hasData ? total.ordersPerHour.flatMap { $0.isFinite ? String(format: "%.1f", $0) : nil } ?? "—" : "—"
        let weight = hasData ? total.totalWeightText : "—"
        let idle = hasData ? total.idleDuration : "—"
        return "Средний заказ: \(amount(total.average))  ·  Заказов в час: \(rate)  ·  Общий вес: \(weight)  ·  Простой исключён: \(idle)"
    }

    private var accessibilitySummary: String {
        [demo ? "Демонстрация, вымышленные данные." : "", "Итоги: \(period).", statusLine,
         "Заработано \(amount(total.gross)). После налога 6 процентов: \(amount(total.net)). Налог: \(amount(total.tax)).",
         "Доход в час до налога: \(amount(total.grossHourly)), после налога: \(amount(total.hourly)).",
         "Активное время: \(hasData ? total.duration : "—"). Заказов: \(hasData ? String(total.count) : "—").",
         "Просроки: \(hasData ? String(total.late) : "—").", detailLine].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Scales the fixed-size poster rather than recomposing its typography for export.
struct IncomePosterPreview: View {
    let total: DayTotal
    let period: String
    let dayCount: Int
    var coverage: String = ""
    var demo: Bool = false

    var body: some View {
        GeometryReader { geometry in
            IncomePosterCanvas(total: total, period: period, dayCount: dayCount, coverage: coverage, demo: demo)
                .scaleEffect(geometry.size.width / 1200, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .aspectRatio(1200.0 / 630.0, contentMode: .fit)
        .clipped()
    }
}

private enum IncomePosterAsset {
    static let image: UIImage? = {
        if let image = UIImage(named: "income-background") { return image }
        let bundle = Bundle.main
        let url = bundle.url(forResource: "income-background", withExtension: "png")
            ?? bundle.url(forResource: "income-background", withExtension: "png", subdirectory: "Resources")
        return url.flatMap { UIImage(contentsOfFile: $0.path) }
    }()
}
