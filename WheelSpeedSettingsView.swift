import SwiftUI

struct WheelSpeedSettingsView: View {
    @StateObject private var preferences = WheelSpeedPreferences.shared
    @State private var input = ""
    @State private var inputError: String?
    @FocusState private var editing: Bool
    var body: some View {
        CourierPage("Поправка скорости", subtitle: "Только показания и звуковой сигнал iPhone") {
            CourierCard {
                Text(preferences.wheelName).font(.headline)
                if let id = preferences.wheelID { Text("Колесо · \(id.suffix(8))").font(.caption).foregroundStyle(Palette.muted) }
                else { Text("Сначала подключи колесо, чтобы сохранить поправку для его Bluetooth-идентификатора.").font(.subheadline).foregroundStyle(Palette.muted) }
                Text(String(format: "%.1f%%", preferences.percentage)).font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Slider(value: Binding(get: { preferences.percentage }, set: { _ = preferences.setPercentage($0) }), in: 50...150, step: 0.1)
                    .tint(Palette.accent).accessibilityIdentifier("wheel.speed.correction.slider")
                HStack(spacing: 12) {
                    Button("−0,1") { _ = preferences.setPercentage(max(50, preferences.percentage - 0.1)) }.buttonStyle(CourierButtonStyle())
                    Button("+0,1") { _ = preferences.setPercentage(min(150, preferences.percentage + 0.1)) }.buttonStyle(CourierButtonStyle())
                }
                HStack(spacing: 10) {
                    TextField("100,0", text: $input).keyboardType(.decimalPad).focused($editing)
                        .padding(12).background(Palette.field, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("wheel.speed.correction.input")
                    Text("%")
                    Button("Применить") { commitInput() }.font(.subheadline.weight(.semibold))
                }
                if let inputError { Text(inputError).font(.caption).foregroundStyle(Palette.warning) }
                Button("Сбросить на 100,0%") { _ = preferences.setPercentage(100); inputError = nil; editing = false }
                    .buttonStyle(CourierButtonStyle()).accessibilityIdentifier("wheel.speed.correction.reset")
            }.disabled(preferences.wheelID == nil)
            CourierCard {
                Text(String(format: "Колесо сообщает 40 км/ч → приложение показывает %.1f км/ч", preferences.corrected(40))).font(.subheadline.weight(.medium))
                Text("Например, при 95,0%: 40 → 38 км/ч. Поправка сохраняется отдельно для каждого колеса и доступна без подключения.").font(.caption).foregroundStyle(Palette.muted)
                Text("Поправка действует на скорость и предупреждения в приложении. В итогах езды она учитывается при записи новых данных; история не пересчитывается.").font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .onAppear { updateInput() }
        .onChange(of: preferences.percentage) { _, _ in if !editing { updateInput() } }
        .onChange(of: editing) { _, value in if !value { updateInput() } }
        .accessibilityIdentifier("wheel.speed.correction.screen")
    }
    private func updateInput() { input = String(format: "%.1f", preferences.percentage) }
    private func commitInput() {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), preferences.setPercentage(value) else { inputError = "Введи значение от 50,0 до 150,0%."; return }
        editing = false; inputError = nil; updateInput()
    }
}
