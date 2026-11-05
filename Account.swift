import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @State private var logoutConfirmation = false
    var body: some View {
        CourierPage("Профиль") {
            if model.demo { DemoBanner() }
            if model.sessionExpired { ReauthenticationCard() }
            CourierCard {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.name).font(.headline)
                        Text(model.demo ? "Демонстрационный аккаунт" : truth(model.profile["courier_active"]) ? "Допуск активен" : model.profile.isEmpty ? "Загружаем профиль…" : "Допуск уточняется").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button { Task { await model.bootstrap() } } label: { Image(systemName: "arrow.clockwise").frame(width: 40, height: 44) }.disabled(model.busy || model.demo).accessibilityLabel("Обновить профиль")
                }
            }
            ShiftControlBar()
            CourierCard("Работа") {
                ShopScopeButton()
                Divider()
                NavigationLink { ScheduleView() } label: { CourierMenuRow(title: "График и запись на выход", symbol: "calendar") }.accessibilityIdentifier("profile.schedule")
                Divider()
                NavigationLink { TerminalView() } label: { CourierMenuRow(title: "Терминал", symbol: "creditcard") }.accessibilityIdentifier("dashboard.terminal")
                Divider()
                NavigationLink { ArchiveView() } label: { CourierMenuRow(title: "Архив заказов", symbol: "archivebox") }
                Divider()
                NavigationLink { EquipmentView() } label: { CourierMenuRow(title: "Оборудование и одежда", symbol: "bag") }
            }
            CourierCard("Оформление") {
                NavigationLink { AppearanceSettingsView() } label: { CourierMenuRow(title: "Внешний вид", symbol: "paintpalette") }.accessibilityIdentifier("profile.appearance")
            }
            CourierCard("Уведомления") {
                NavigationLink { ExpressNotificationSettingsView() } label: { CourierMenuRow(title: "Экспрессы на смене", symbol: "bell") }.accessibilityIdentifier("profile.notifications")
                Divider()
                NavigationLink { TelegramNotificationStatusView() } label: { CourierMenuRow(title: "Бот в Telegram", symbol: "paperplane") }.accessibilityIdentifier("profile.telegram")
            }
            CourierCard("Покупки") {
                Button { CustomerVkusVillApp.open() } label: { CourierMenuRow(title: "Открыть ВкусВилл · баллы", symbol: "creditcard.and.123") }.buttonStyle(.plain).accessibilityIdentifier("profile.customer-app")
            }
            CourierCard("Колесо") {
                NavigationLink { WheelSpeedSettingsView() } label: { CourierMenuRow(title: "Скорость и точность", symbol: "speedometer") }
                Divider()
                NavigationLink { WheelDashboardSettingsView() } label: { CourierMenuRow(title: "Плитки телеметрии", symbol: "square.grid.2x2") }
                Divider()
                NavigationLink { WheelAlarmSettingsView() } label: { CourierMenuRow(title: "Звуковые предупреждения", symbol: "speaker.wave.2") }
            }
            HStack(spacing: 4) {
                Text("Завайбкожено by").foregroundStyle(Palette.muted)
                Link("survive", destination: URL(string: "https://t.me/survivee")!).foregroundStyle(Palette.accent).accessibilityIdentifier("profile.author")
            }.font(.caption2).frame(maxWidth: .infinity).padding(.top, 4)
            Button(model.demo ? "Выйти из деморежима" : "Выйти из аккаунта") { logoutConfirmation = true }.buttonStyle(CourierButtonStyle()).disabled(model.busy)
        }.courierBrandHeader().confirmationDialog(model.demo ? "Выйти из деморежима?" : "Удалить локальный вход в ВВ?", isPresented: $logoutConfirmation, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { model.logout() }
        }
    }

}

struct EquipmentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rows: [(String, String)] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    var body: some View {
        CourierPage("Оборудование и ТМЦ", subtitle: "Что закреплено за тобой в ВВ", artwork: 3) {
            if model.demo { DemoBanner() }
            if loading { CourierCard { ProgressView("Загружаем оборудование…") } }
            if let failure { CourierErrorCard(message: failure) { Task { await load() } } }
            ForEach(rows.indices, id: \.self) { index in CourierCard { HStack { Text(rows[index].0).font(.subheadline); Spacer(); Text(rows[index].1).font(.headline).monospacedDigit() } } }
            if loaded && rows.isEmpty && failure == nil { CourierEmpty(title: "Оборудование не указано", message: "ВВ не показывает закреплённые ТМЦ в этом разделе.", symbol: "bag") }
            NavigationLink { TerminalView() } label: { Label("Терминал и код сдачи", systemImage: "creditcard") }.buttonStyle(CourierButtonStyle(primary: true))
            Button("Обновить") { Task { await load() } }.buttonStyle(CourierButtonStyle()).disabled(loading)
        }.navigationBarTitleDisplayMode(.inline).task { await load() }.refreshable { await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; failure = nil; loaded = false
        defer { loading = false }
        if model.demo { rows = [("Демонстрационная термосумка", "1"), ("Демонстрационный терминал", "1")]; loaded = true; return }
        let owner = model.identity, api = model.api
        do {
            let result = try await api.request("https://courier-profile.vkusvill.ru/v1/courier/me/tmc")
            guard model.identity == owner, !Task.isCancelled else { return }
            let data = result as? [String: Any] ?? [:]
            if let list = result as? [[String: Any]] ?? data["items"] as? [[String: Any]] ?? data["tmc"] as? [[String: Any]] {
                rows = list.map { (string($0["name"] ?? $0["title"] ?? $0["tmc_name"]), string($0["quantity"] ?? $0["amount"] ?? $0["count"])) }.filter { !$0.0.isEmpty }
            } else { throw CourierError(message: "Не удалось прочитать список оборудования. Обнови данные позже.") }
            loaded = true
        } catch is CancellationError { }
        catch { if model.identity == owner && !Task.isCancelled { rows = []; failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } } }
    }
}
