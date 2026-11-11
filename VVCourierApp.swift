import SwiftUI
import UIKit

@main @MainActor
struct VVCourierApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppTheme.storageKey) private var palette = AppTheme.codex.rawValue
    init() {
        // Retire the old Telegram connection locally before any monitoring starts.
        _ = TelegramNotificationPreferences.shared
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { fputs("VV startup: App init\n", stderr) }
        #endif
        ExpressNotificationCenter.shared.registerBackgroundRefresh()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { fputs("VV startup: notification registration complete\n", stderr) }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            CourierThemeRoot(theme: AppTheme(rawValue: palette) ?? .codex).environmentObject(model)
                .preferredColorScheme((!model.demo || model.originalFixture ? model.webColorScheme : nil)
                    ?? (AppAppearance(rawValue: appearance) ?? .system).colorScheme)
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }
}

private struct CourierThemeRoot: View {
    @Environment(\.colorScheme) private var colorScheme
    let theme: AppTheme
    var body: some View {
        RootView()
            .tint(Color(uiColor: theme.colors(dark: colorScheme == .dark).accent))
            .foregroundStyle(Palette.text)
            .environment(\.courierTheme, theme)
    }
}

@MainActor final class AppModel: ObservableObject {
    let originalFixture = ProcessInfo.processInfo.arguments.contains("--original-ui-testing")
    @Published var session = SessionStore.load()
    @Published var demo = false
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var active = false
    @Published var shiftKnown = false
    @Published var sessionExpired = false
    @Published var loginPresented = false
    @Published var shopsPresented = false
    @Published var profile: [String: Any] = [:]
    @Published var shops: [Shop] = []
    @Published var selectedShopID: Int? {
        didSet { if let session, !demo, !restoringShopSelection { UserDefaults.standard.set(selectedShopID, forKey: "shop-selection.\(session.courierID)") } }
    }
    @Published var tab = 0
    @Published var selectedFeed: Feed = .available
    @Published var demoMine: [Parcel] = []
    @Published var demoTaken = Set<String>()
    @Published var demoQueueJoined = false
    @Published var revision = 0
    @Published private var authGeneration = 0
    @Published var errorPresenters: [UUID] = []
    @Published var notificationTarget: ExpressNotificationTarget?
    // Only the visible website controls the window chrome. Native sheets and
    // the wheel restore the user's configured appearance through a nil value.
    @Published var webColorScheme: ColorScheme?
    private var bootstrapTaskID: UUID?
    private var bootstrapWork: Task<Void, Never>?
    private var bootstrapIdentity: String?
    private var operationID: UUID?
    private var operationWork: Task<Void, Never>?
    private var restoringShopSelection = false
    private var websiteActivityRevision: UInt64 = 0
    struct ActivityObservation {
        fileprivate let identity: String
        fileprivate let token: String?
        fileprivate let websiteRevision: UInt64
    }
    var api: CourierAPI { CourierAPI(session: session, shopNumbers: selectedShopID.map { [$0] } ?? shops.map(\.id)) }
    var identity: String { demo ? "demo" : (session?.courierID ?? "guest") + ":\(authGeneration)" }
    var shopScopeKey: String { identity + ":" + (selectedShopID.map(String.init) ?? "all") }
    var shopTitle: String { selectedShopID.map { id in shops.first(where: { $0.id == id })?.title ?? "Магазин №\(id)" } ?? "Все магазины" }
    var name: String { let value = string(profile["name_courier"]); return value.isEmpty ? "Курьер" : value }
    init() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: "appearance") }
        if ProcessInfo.processInfo.arguments.contains("--demo") || originalFixture { activateDemo() }
        if originalFixture && (ProcessInfo.processInfo.arguments.contains("--original-notification-preload") || ProcessInfo.processInfo.arguments.contains("--original-express-preview")) {
            session = Session(token: "offline-fixture-token", courierID: "demo")
        }
        if originalFixture && ProcessInfo.processInfo.arguments.contains("--original-notification-preload") {
            notificationTarget = ExpressNotificationTarget(courierID: "demo", parcelID: "22421", kind: .ready)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { fputs("VV startup: model demo=\(demo), fixture=\(originalFixture)\n", stderr) }
        #endif
    }
    func perform(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        let owner = identity, id = UUID()
        operationID = id; busy = true
        operationWork = Task {
            defer { if operationID == id { operationID = nil; operationWork = nil; busy = false } }
            do { try Task.checkCancellation(); guard identity == owner else { return }; try await operation(); if identity == owner { revision += 1 } }
            catch is CancellationError { }
            catch { if identity == owner { revision += 1; handle(error) } }
        }
    }
    func handle(_ failure: Error) {
        if let value = failure as? CourierError, value.statusCode == 401 { sessionExpired = true }
        if (failure as? CourierError)?.businessCode == ColdControlSignal.businessError { return }
        error = failure.localizedDescription
    }
    func finishLogin(_ value: Session) throws {
        try SessionStore.save(value)
        invalidateAccountWork()
        demo = false; session = value; sessionExpired = false; loginPresented = false
        profile = [:]; shops = []; active = false; shiftKnown = false; resetShopSelection(); revision += 1; authGeneration += 1
    }
    func activateDemo() {
        invalidateAccountWork()
        demo = true; active = false; shiftKnown = true; sessionExpired = false
        shops = [Shop(id: 101, address: "Учебный проспект, 1", name: "Магазин №101", active: true, latitude: 60.073, longitude: 30.335), Shop(id: 202, address: "Тестовая улица, 8", name: "Магазин №202", latitude: 60.078, longitude: 30.34)]
        selectedShopID = nil; profile = ["name_courier": "Демо-курьер", "courier_active": true]
        demoMine = Array(Demo.orders(.mine).prefix(2)); if demoMine.count > 1 { demoMine[1].status = "on_the_way" }
        InspectionDemoState.shared.checked = []
        if ProcessInfo.processInfo.arguments.contains("--demo-inspection-batch") {
            demoMine = Array(Demo.orders(.mine).prefix(3))
            for index in demoMine.indices { demoMine[index].status = "pickuped" }
        }
        demoTaken = []; demoQueueJoined = false; revision += 1
    }
    func logout() {
        invalidateAccountWork()
        if !demo { SessionStore.clear(); session = nil }
        demo = false; active = false; shiftKnown = false; resetShopSelection()
        profile = [:]; shops = []; demoMine = []; demoTaken = []; sessionExpired = false; tab = 0
        revision += 1
    }
    private func invalidateAccountWork() {
        bootstrapWork?.cancel(); bootstrapWork = nil; bootstrapIdentity = nil; bootstrapTaskID = nil
        operationWork?.cancel(); operationWork = nil
        operationID = nil; busy = false; notificationTarget = nil
        error = nil; notice = nil
        ExpressNotificationCenter.shared.endObservation()
    }
    private func resetShopSelection() {
        restoringShopSelection = true; selectedShopID = nil; restoringShopSelection = false
    }
    func demoOrders(_ feed: Feed) -> [Parcel] {
        let all = feed == .mine ? demoMine : Demo.orders(feed).filter { !demoTaken.contains($0.id) }
        return feed == .mine || selectedShopID == nil ? all : all.filter { $0.shopID == selectedShopID }
    }
    func activityObservation() -> ActivityObservation {
        ActivityObservation(identity: identity, token: session?.token, websiteRevision: websiteActivityRevision)
    }
    /// The website owns shift mutations. A native read already in flight must
    /// not undo a newer activity response observed from that same website.
    func observeWebsiteActivity(_ value: Bool) {
        guard !demo, session != nil else { return }
        websiteActivityRevision &+= 1
        active = value; shiftKnown = true
    }
    @discardableResult
    func observeNativeActivity(_ value: Bool?, ifCurrent observation: ActivityObservation) -> Bool {
        guard !demo, session != nil, !sessionExpired,
              identity == observation.identity, session?.token == observation.token,
              websiteActivityRevision == observation.websiteRevision else { return false }
        if let value { active = value; shiftKnown = true }
        else { shiftKnown = false }
        return true
    }
    func bootstrap() async {
        guard !demo, let session else { return }
        let owner = identity
        if let bootstrapWork, bootstrapIdentity == owner { await bootstrapWork.value; return }
        bootstrapWork?.cancel()
        bootstrapIdentity = owner
        let work = Task { await loadAccount(session: session, owner: owner) }
        bootstrapWork = work
        await work.value
        if bootstrapIdentity == owner { bootstrapWork = nil; bootstrapIdentity = nil }
    }
    private func loadAccount(session: Session, owner: String) async {
        let id = UUID(); bootstrapTaskID = id
        let initialActivity = activityObservation()
        func current() -> Bool { bootstrapTaskID == id && identity == owner && self.session?.token == session.token && !demo && !Task.isCancelled }
        let client = CourierAPI(session: session)
        do {
            let values = try await client.shops()
            guard current() else { return }
            shops = values
            if let saved = UserDefaults.standard.object(forKey: "shop-selection.\(session.courierID)") as? Int, values.contains(where: { $0.id == saved }) { selectedShopID = saved }
            else if let selectedShopID, !values.contains(where: { $0.id == selectedShopID }) { self.selectedShopID = nil }
            sessionExpired = false
            do { let value = try await client.profile(); if current() { profile = value } } catch { if current() { handle(error) } }
            guard current() else { return }
            let activity = activityObservation()
            do { let value = try await client.activeShift(); if current() { observeNativeActivity(value, ifCurrent: activity) } }
            catch { if current(), observeNativeActivity(nil, ifCurrent: activity) { handle(error) } }
        } catch is CancellationError { }
        catch { if current(), observeNativeActivity(nil, ifCurrent: initialActivity) { handle(error) } }
    }
}

struct CourierErrors: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onAppear { if !model.errorPresenters.contains(id) { model.errorPresenters.append(id) } }
            .onDisappear { model.errorPresenters.removeAll { $0 == id } }
            .alert("VV Courier", isPresented: Binding(get: { model.error != nil && model.errorPresenters.last == id }, set: { if !$0 { model.error = nil } })) {
                Button("Понятно", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private var wheelContextKey: String { "\(model.identity):\(model.active):\(model.shiftKnown):\(model.sessionExpired)" }
    var body: some View {
        Group {
            if !model.demo || model.originalFixture {
                OriginalCourierShell()
            } else {
                TabView(selection: $model.tab) {
                    NavigationStack { OrdersView() }.tabItem { Label("Заказы", systemImage: "shippingbox") }.tag(0)
                    NavigationStack { QueueView() }.tabItem { Label("Очередь", systemImage: "person.2") }.tag(1)
                    NavigationStack { WheelView() }.tabItem { Label("Колесо", systemImage: "circle.circle") }.tag(2)
                    IncomeView().tabItem { Label("Доходы", systemImage: "chart.bar.xaxis") }.tag(3)
                    NavigationStack { AccountView() }.tabItem { Label("Профиль", systemImage: "slider.horizontal.3") }.tag(4)
                }.id(model.identity).toolbarBackground(Palette.surface, for: .tabBar).toolbarBackground(.visible, for: .tabBar)
            }
        }
        .sheet(isPresented: $model.shopsPresented) { ShopPickerView() }
        .modifier(CourierErrors())
        .modifier(ColdControlMonitoring())
        .modifier(ExpressNotificationMonitoring())
        .task(id: model.identity) { await model.bootstrap() }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { fputs("VV startup: Root appeared demo=\(model.demo), fixture=\(model.originalFixture)\n", stderr) }
            #endif
            updateWheelContext()
        }
        .onChange(of: wheelContextKey) { _, _ in updateWheelContext() }
        .task(id: model.demo) { WheelConnection.shared.activate(demo: model.demo) }
        .onChange(of: scenePhase) { _, value in
            if value == .active {
                updateWheelContext()
                WheelConnection.shared.activate(demo: model.demo)
                if !model.sessionExpired { Task { await model.bootstrap() } }
            } else { WheelRideStore.shared.flush() }
        }
    }
    private func updateWheelContext() {
        WheelRideStore.shared.setContext(courierID: model.session?.courierID, active: model.active, known: model.shiftKnown && !model.sessionExpired, demo: model.demo)
    }
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var requestedPhone: String?
    @State private var cooldown: Date?
    @State private var sending = false
    @State private var failure: String?
    @State private var authWork: Task<Void, Never>?
    private var digits: String { let value = phone.filter(\.isNumber); return value.count == 11 && (value.first == "7" || value.first == "8") ? String(value.dropFirst()) : value }
    var body: some View {
        NavigationStack {
            CourierPage("Вход", subtitle: "ВкусВилл · курьер") {
                CourierCard("Вход в ВкусВилл") {
                    if let requestedPhone {
                        Text("Код для +7 \(requestedPhone)").font(.subheadline).foregroundStyle(Palette.muted)
                        TextField("Код из SMS", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).accessibilityIdentifier("auth.code").padding(14).background(Palette.field, in: RoundedRectangle(cornerRadius: 11))
                        Button("Войти") { authenticate(phone: requestedPhone) }.buttonStyle(CourierButtonStyle(primary: true)).disabled(sending || code.filter(\.isNumber).count != 6)
                        Button("Изменить номер") { self.requestedPhone = nil; code = "" }.font(.caption).disabled(sending)
                    } else {
                        TextField("+7 999 123-45-67", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber).accessibilityIdentifier("auth.phone").padding(14).background(Palette.field, in: RoundedRectangle(cornerRadius: 11))
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(ceil((cooldown ?? .distantPast).timeIntervalSince(context.date))))
                            Button(seconds > 0 ? "Повторный запрос через \(seconds) с" : "Получить код") { requestCode() }.buttonStyle(CourierButtonStyle(primary: true)).disabled(sending || digits.count != 10 || seconds > 0)
                        }
                    }
                    if sending { ProgressView().frame(maxWidth: .infinity) }
                    if let failure { Text(failure).font(.subheadline).foregroundStyle(Palette.warning) }
                    Text("Новый вход может завершить сессию в родном приложении ВВ. Код отправляется только по твоему нажатию.").font(.caption).foregroundStyle(Palette.muted)
                }
                CourierCard {
                    Button { model.activateDemo(); dismiss() } label: { Label("Посмотреть демоверсию", systemImage: "play.circle") }.buttonStyle(CourierButtonStyle()).accessibilityIdentifier("auth.demo")
                    Text("Данные вымышленные. Можно проверить интерфейс и рабочие шаги без аккаунта.").font(.caption).foregroundStyle(Palette.muted)
                }
            }.modifier(CourierErrors())
        }.onDisappear { authWork?.cancel() }
    }
    private func requestCode() {
        let value = digits
        guard !sending, value.count == 10, (cooldown ?? .distantPast) <= Date() else { return }
        let owner = model.identity
        sending = true; failure = nil; cooldown = Date().addingTimeInterval(60)
        authWork = Task {
            defer { sending = false }
            do { try await CourierAPI(session: nil).requestCode(phone: value); guard model.identity == owner, !Task.isCancelled else { return }; requestedPhone = value }
            catch { if model.identity == owner && !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
    private func authenticate(phone: String) {
        guard !sending else { return }; sending = true; failure = nil
        let owner = model.identity
        authWork = Task {
            defer { sending = false }
            do { let value = try await CourierAPI(session: nil).login(phone: phone, code: code.filter(\.isNumber)); guard model.identity == owner, !Task.isCancelled else { return }; try model.finishLogin(value); dismiss() }
            catch { if model.identity == owner && !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

struct DemoBanner: View {
    var body: some View { Label("Деморежим · данные вымышлены", systemImage: "flask").font(.caption2).foregroundStyle(Palette.muted).accessibilityIdentifier("demo.banner") }
}

struct ShopScopeButton: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Button { model.shopsPresented = true } label: {
            HStack(spacing: 8) { Image(systemName: "building.2").foregroundStyle(Palette.accent); Text(model.shopTitle).font(.subheadline.weight(.medium)).lineLimit(1); Spacer(minLength: 4); Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted) }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("shops.scope")
    }
}

struct ShopPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var failure: String?
    @State private var loading = false
    private var filtered: [Shop] { query.isEmpty ? model.shops : model.shops.filter { "\($0.id) \($0.name) \($0.address)".localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            CourierPage("Магазины", subtitle: "Список доступен из твоего аккаунта ВВ.", artwork: 2) {
                CourierCard {
                    TextField("Номер или адрес", text: $query).accessibilityIdentifier("shops.search").submitLabel(.done)
                        .onSubmit { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    Button { model.selectedShopID = nil; dismiss() } label: { HStack { Text("Все доступные магазины"); Spacer(); if model.selectedShopID == nil { Image(systemName: "checkmark") } } }.padding(.vertical, 8).accessibilityIdentifier("shops.all")
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let failure { CourierErrorCard(message: failure) { load() } }
                ForEach(filtered) { shop in
                    Button {
                        model.selectedShopID = shop.id; dismiss()
                    } label: {
                        CourierCard {
                            HStack { Text(shop.title).font(.headline); Spacer(); if model.selectedShopID == shop.id { Image(systemName: "checkmark.circle.fill") } }
                            if !shop.address.isEmpty { Text(shop.address).font(.subheadline).foregroundStyle(Palette.muted) }
                            if shop.active { Text("Активный магазин").font(.caption).foregroundStyle(Palette.success) }
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("shop.\(shop.id)")
                }
                if !loading && failure == nil && filtered.isEmpty { CourierEmpty(title: "Магазины не найдены", message: query.isEmpty ? "Обнови список. Если ВВ не назначил магазины, уточни доступ у поддержки." : "Попробуй другой номер или часть адреса.", symbol: "building.2") }
                Button("Обновить список") { load() }.buttonStyle(CourierButtonStyle()).disabled(loading || model.demo)
            }.navigationBarTitleDisplayMode(.inline).toolbar { Button("Готово") { dismiss() } }.modifier(CourierErrors())
        }.task { if model.shops.isEmpty { load() } }
    }
    private func load() {
        guard !model.demo, !loading else { return }; loading = true; failure = nil
        let owner = model.identity, client = model.api
        Task {
            defer { loading = false }
            do { let shops = try await client.shops(); guard model.identity == owner, !Task.isCancelled else { return }; model.shops = shops }
            catch { guard model.identity == owner, !Task.isCancelled else { return }; failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } }
        }
    }
}
