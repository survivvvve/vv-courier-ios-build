import SwiftUI
import Combine

struct WheelDashboardSettingsView: View {
    @StateObject private var preferences = WheelDashboardPreferences.shared
    var body: some View {
        List {
            Section {
                ForEach(preferences.metrics) { metric in
                    HStack {
                        Text(metric.title)
                        Spacer()
                        Text(metric.unit).foregroundStyle(Palette.muted)
                    }.accessibilityIdentifier("wheel.dashboard.metric.\(metric.rawValue)")
                        .deleteDisabled(preferences.metrics.count <= 1)
                        .listRowBackground(Rectangle().fill(Palette.surface))
                }
                .onMove { preferences.move(from: $0, to: $1) }
                .onDelete { indices in
                    let deleting = indices.map { preferences.metrics[$0] }
                    for metric in deleting { preferences.remove(metric) }
                }
            } header: { Text("На экране колеса") } footer: {
                Text("Перетаскивай строки для изменения порядка. Можно убрать любой показатель; на экране останется хотя бы один.")
            }
            let hidden = WheelMetric.allCases.filter { !preferences.metrics.contains($0) }
            if !hidden.isEmpty {
                Section("Добавить показатель") {
                    ForEach(hidden) { metric in
                        Button { preferences.add(metric) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(metric.title + " · " + metric.unit).foregroundStyle(Palette.text)
                                    if let note = metric.note { Text(note).font(.caption).foregroundStyle(Palette.muted) }
                                }
                                Spacer(); Image(systemName: "plus.circle").foregroundStyle(Palette.accent)
                            }
                        }.accessibilityIdentifier("wheel.dashboard.add.\(metric.rawValue)")
                            .listRowBackground(Rectangle().fill(Palette.surface))
                    }
                }
            }
            Section {
                Button("Вернуть стандартный набор") { preferences.restore() }.listRowBackground(Rectangle().fill(Palette.surface))
            } footer: {
                Text("Без свежих данных показывается «—». Заряд приблизительный. Знак тока и наклона сохраняется таким, каким его передаёт прошивка.")
            }
        }
        .foregroundStyle(Palette.text)
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Приборы колеса").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(Palette.background)
        .accessibilityIdentifier("wheel.dashboard.settings")
    }
}
