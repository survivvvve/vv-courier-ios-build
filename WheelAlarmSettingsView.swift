import SwiftUI

struct WheelAlarmSettingsView: View {
    @StateObject private var preferences = WheelAlarmPreferences.shared
    @StateObject private var monitor = WheelPhoneAlarmMonitor.shared
    var body: some View {
        CourierPage("Звуковые сигналы", subtitle: "Сигналы iPhone · отдельно от настроек колеса") {
            ruleCard("Скорость", rule: $preferences.speed, pwm: false)
            ruleCard("ШИМ", rule: $preferences.pwm, pwm: true)
            CourierCard {
                Toggle("Приглушать музыку", isOn: $preferences.duckMusic).accessibilityIdentifier("wheel.alarms.duck-music")
                Text("Музыка становится тише на время писка и возвращается к прежней громкости после него.").font(.caption).foregroundStyle(Palette.muted)
                Divider()
                Text("Повтор — с выбранным интервалом. Сброс — на 2 км/ч или 2% ниже порога.").font(.subheadline)
                Text("Сигналы работают по свежим данным. В фоне зависят от связи Bluetooth и ограничений iOS. Громкость — как у мультимедиа.").font(.caption).foregroundStyle(Palette.muted)
            }
            if let error = monitor.audioError { CourierCard { Text(error).font(.subheadline).foregroundStyle(Palette.warning) } }
        }.accessibilityIdentifier("wheel.alarms.settings")
    }
    private func ruleCard(_ title: String, rule: Binding<WheelPhoneAlarmRule>, pwm: Bool) -> some View {
        CourierCard(title) {
            Toggle("Предупреждать", isOn: rule.enabled).accessibilityIdentifier(pwm ? "wheel.alarms.pwm.enabled" : "wheel.alarms.speed.enabled")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Порог")
                    Spacer()
                    Text(String(format: "%.0f %@", rule.wrappedValue.threshold, pwm ? "%" : "км/ч")).monospacedDigit().fontWeight(.semibold)
                }
                Slider(value: rule.threshold, in: pwm ? 30...100 : 5...120, step: 1).tint(Palette.accent)
            }.font(.subheadline)
            Stepper(value: rule.repeatInterval, in: 1...30, step: 1) {
                Text("Повторять каждые \(Int(rule.wrappedValue.repeatInterval)) с").font(.subheadline).monospacedDigit()
            }
            Button { monitor.preview(pwm: pwm) } label: { Label("Проверить звук", systemImage: "speaker.wave.2") }
                .buttonStyle(CourierButtonStyle()).accessibilityIdentifier(pwm ? "wheel.alarms.pwm.preview" : "wheel.alarms.speed.preview")
        }
    }
}
