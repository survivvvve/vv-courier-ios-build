import SwiftUI

struct RideIncomeReport: View {
    let summary: WheelRideSummary
    let netIncome: Double?
    let dayCount: Int
    var demo = false
    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    private var perKilometer: Double? {
        guard let netIncome, netIncome.isFinite, netIncome >= 0, summary.meters.isFinite, summary.meters > 0 else { return nil }
        let amount = netIncome / (summary.meters / 1000)
        return amount.isFinite ? amount : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(dayCount == 1 ? "Езда за день" : "Езда за период", systemImage: "circle.circle").font(.subheadline.weight(.semibold))
            if demo {
                Text("В деморежиме езда не записывается.").font(.caption).foregroundStyle(Palette.muted)
            } else if !summary.hasData {
                Text("Пока нет записей колеса. Они появятся после езды с подключённым колесом во время активной смены.").font(.caption).foregroundStyle(Palette.muted)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    CourierMetric(title: "Записанный путь", value: String(format: "%.2f км", summary.meters / 1000), symbol: "point.topleft.down.to.point.bottomright.curvepath")
                    CourierMetric(title: "В движении", value: movingTime, symbol: "clock")
                    CourierMetric(title: "Средняя скорость", value: summary.averageSpeed.map { String(format: "%.1f км/ч", $0) } ?? "—", symbol: "speedometer")
                    CourierMetric(title: "Макс. скорость", value: summary.maxSpeed.map { String(format: "%.1f км/ч", $0) } ?? "—", symbol: "arrow.up.right")
                    CourierMetric(title: "Макс. ШИМ", value: summary.maxPWM.map { String(format: "%.1f%%", $0) } ?? "—", symbol: "bolt")
                    CourierMetric(title: "Макс. температура", value: summary.maxTemperature.map { String(format: "%.0f °C", $0) } ?? "—", symbol: "thermometer.medium")
                }
                if let amount = perKilometer {
                    HStack(alignment: .firstTextBaseline) {
                        Text("После налога на км · оценка").font(.caption).foregroundStyle(Palette.muted)
                        Spacer(minLength: 8)
                        Text("≈ " + money(amount)).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(Palette.accent)
                    }.accessibilityIdentifier("income.riding.per-km")
                }
                VStack(alignment: .leading, spacing: 5) {
                    if dayCount > 1 { Text("Записи колеса за \(summary.daysWithData) из \(dayCount) дней.") }
                    if summary.hasGaps { Text("Пробег и время — только по записанным участкам смены.") }
                    if perKilometer != nil {
                        Text("₽/км — доход после налога за выбранный период, делённый на записанный путь. Незаписанные участки могут завысить оценку.")
                    } else if netIncome == nil {
                        Text("Для ₽/км нужен доход за весь выбранный период.")
                    }
                }.font(.caption2).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("income.riding")
    }
    private var movingTime: String {
        let minutes = max(0, integer(floor(summary.movingSeconds / 60)) ?? 0)
        if summary.movingSeconds > 0 && minutes == 0 { return "< 1 мин" }
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }
}
