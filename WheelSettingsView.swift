import SwiftUI

struct WheelSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var wheel = WheelConnection.shared
    @State private var baseline: [WheelSettingKey: Int] = [:]
    @State private var draft: [WheelSettingKey: Int] = [:]
    @State private var review = false
    @State private var reviewedChanges: [WheelSettingKey: Int] = [:]
    @State private var reviewedBaseline: [WheelSettingKey: Int] = [:]
    private var changes: [WheelSettingKey: Int] { draft.filter { baseline[$0.key] != $0.value && !($0.key.isPID && $0.key != .pidEnabled && draft[.pidEnabled] == 0) } }
    private let groups: [(String, [WheelSettingKey])] = [
        ("Педали", [.hardness,.pedalAngle,.stockAssist,.dipCompensation]),
        ("Скорость и защита", [.tiltbackSpeed,.pwmTiltback,.speedAlarm,.lateralCutoff]),
        ("Дисплей, заряд и режимы", [.displayBrightness,.keyVolume,.chargeLimit,.units,.voltageTrim,.lowBattery,.highSpeed,.transport]),
        ("Раздельный ассист", [.assistEnabled,.assistAcceleration,.assistAccelerationLimit,.assistBraking,.assistBrakingLimit]),
        ("ПИД-регулятор", [.pidEnabled,.pidKa,.pidKg,.pidKc])
    ]
    var body: some View {
        CourierPage("Настройки колеса", subtitle: (wheel.sample?.modelName ?? "Колесо") + " · изменения после подтверждения") {
            if model.demo { DemoBanner() }
            Text("Сначала остановись и переведи колесо в парковку P. Значения ниже получены с колеса; ползунки меняют только черновик.")
                .font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("wheel.settings.screen")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ForEach(groups.indices, id: \.self) { index in
                    CourierCard {
                        DisclosureGroup(groups[index].0) {
                            VStack(alignment: .leading, spacing: 20) {
                                if index == 3 { Text("50 — штатный масштаб; 100 — двойной масштаб до заданного предела наклона.").font(.caption).foregroundStyle(Palette.muted) }
                                if index == 4 { Text("Ka задаёт упор педалей, Kg — успокоение рывков, Kc — подхват под нагрузкой. Весь набор ПИД применяется одной транзакцией.").font(.caption).foregroundStyle(Palette.muted) }
                                ForEach(groups[index].1) { key in settingRow(key, at: context.date) }
                            }.padding(.top, 16)
                        }.font(.headline)
                    }
                }
            }
            if let pending = wheel.pending { HStack { ProgressView(); Text(pending).font(.subheadline) }.frame(maxWidth: .infinity) }
            if let message = wheel.message { Text(message).font(.subheadline).foregroundStyle(Palette.muted) }
            Button(changes.isEmpty ? "Нет изменений" : "Проверить изменения · \(changes.count)") { reviewedChanges = changes; reviewedBaseline = baseline; review = true }
                .buttonStyle(CourierButtonStyle(primary: true)).disabled(changes.isEmpty || !wheel.controlsAvailable() || changes.keys.contains(where: { wheel.settingsValue($0) == nil }))
                .accessibilityIdentifier("wheel.settings.apply")
            Button("Вернуть значения с колеса") { draft = [:]; baseline = [:]; synchronize() }.buttonStyle(CourierButtonStyle()).disabled(wheel.pending != nil)
            Text("Если связь оборвётся, повторной отправки не будет. Проверь текущие значения: часть обычных настроек могла примениться отдельно.").font(.caption).foregroundStyle(Palette.muted)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { synchronize() }
        .onChange(of: wheel.settingsRevision) { _, _ in synchronize() }
        .confirmationDialog("Применить настройки на остановленном колесе в P?", isPresented: $review, titleVisibility: .visible) {
            Button("Колесо в P · применить") { wheel.applySettings(reviewedChanges, baseline: reviewedBaseline) }
        } message: { Text(changeDescription) }
    }
    private var changeDescription: String {
        WheelSettingKey.allCases.compactMap { key in
            guard let value = reviewedChanges[key], let old = reviewedBaseline[key] else { return nil }
            return key.title + ": " + key.formatted(old) + " → " + key.formatted(value)
        }.joined(separator: "\n")
    }
    private func synchronize() {
        for key in WheelSettingKey.allCases {
            guard let current = wheel.settingsValue(key) else { continue }
            if draft[key] == nil || draft[key] == baseline[key] || draft[key] == current { draft[key] = current; baseline[key] = current }
        }
    }
    @ViewBuilder private func settingRow(_ key: WheelSettingKey, at date: Date) -> some View {
        let current = wheel.settingsValue(key, at: date)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(key.title).font(.subheadline.weight(.medium))
                Spacer()
                if let current { Text(key.formatted(current)).font(.subheadline).foregroundStyle(Palette.muted).monospacedDigit() }
            }
            if let current, let value = draft[key] {
                let binding = Binding<Int>(get: { draft[key] ?? current }, set: { draft[key] = $0 })
                if key.isToggle {
                    Toggle("Новое значение", isOn: Binding(get: { binding.wrappedValue == 1 }, set: { binding.wrappedValue = $0 ? 1 : 0 })).font(.subheadline)
                } else if key == .units {
                    Picker("Единицы", selection: binding) { Text("км/ч").tag(0); Text("мили/ч").tag(1) }.pickerStyle(.segmented)
                } else {
                    if key.allowsDisabled {
                        Toggle("Включено", isOn: Binding(get: { binding.wrappedValue != 200 }, set: { binding.wrappedValue = $0 ? min(key.range.upperBound, max(key.range.lowerBound, current == 200 ? key.range.lowerBound : current)) : 200 })).font(.subheadline)
                    }
                    if value != 200 {
                        Slider(value: Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) }), in: Double(key.range.lowerBound)...Double(key.range.upperBound), step: Double(key.step))
                        HStack { Text(key.formatted(key.range.lowerBound)); Spacer(); Text(key.formatted(key.range.upperBound)) }.font(.caption2).foregroundStyle(Palette.muted)
                    }
                }
                if current != value { Text("Сейчас: \(key.formatted(current))  →  станет: \(key.formatted(value))").font(.caption).foregroundStyle(Palette.accent) }
            } else { Text("Ожидаем свежие настройки с колеса…").font(.caption).foregroundStyle(Palette.muted) }
        }.disabled(wheel.pending != nil || !wheel.connected || (key.isPID && key != .pidEnabled && draft[.pidEnabled] == 0)).accessibilityIdentifier("wheel.setting.\(key.rawValue)")
    }
}
