import SwiftUI
import UserNotifications
import BackgroundTasks
import UIKit

final class ExpressNotificationPreferences: ObservableObject {
    static let shared = ExpressNotificationPreferences()
    @Published var enabled = UserDefaults.standard.object(forKey: "express.notifications.enabled") as? Bool ?? true { didSet { UserDefaults.standard.set(enabled, forKey: "express.notifications.enabled") } }
    @Published var created = UserDefaults.standard.object(forKey: "express.notifications.created") as? Bool ?? true { didSet { UserDefaults.standard.set(created, forKey: "express.notifications.created") } }
    @Published var ready = UserDefaults.standard.object(forKey: "express.notifications.ready") as? Bool ?? true { didSet { UserDefaults.standard.set(ready, forKey: "express.notifications.ready") } }
    func allows(_ kind: ExpressEventKind) -> Bool { enabled && (kind == .created ? created : ready) }
}

@MainActor final class ExpressNotificationCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ExpressNotificationCenter()
    static let backgroundID = "ru.local.vvcourier.express-refresh"
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var error: String?
    @Published private(set) var expiredCourierID: String?
    @Published private(set) var foregroundEvents: [ExpressOrderEvent] = []
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var observedShift: Bool?
    @Published private(set) var status = "Ожидаем входа в ВВ"
    @Published private(set) var testStatus: String?
    @Published var destination: ExpressNotificationTarget?
    private let notifications = UNUserNotificationCenter.current()
    private let preferences = ExpressNotificationPreferences.shared
    private let ledgerKey = "express.notifications.ledger.v1"
    private var ledger: ExpressNotificationLedger
    private var pending: [ExpressOrderEvent] = []
    private var generation = UUID()
    private var context = ""
    private var pollTask: Task<Bool?, Never>?
    private var pollID = UUID()
    private var backgroundPolls: [UUID: UUID] = [:]
    private var registered = false
    private var lastSave = Date.distantPast
    private var freshActiveAt = Date.distantPast
    private var inbox = ExpressForegroundInbox()
    #if DEBUG
    private var uiPreviewPresented = false
    private var uiPreviewActive = false
    #endif

    private struct SavedScope: Codable { let courierID: String; let shops: [Int] }
    private override init() {
        ledger = UserDefaults.standard.data(forKey: "express.notifications.ledger.v1").flatMap { try? JSONDecoder().decode(ExpressNotificationLedger.self, from: $0) } ?? ExpressNotificationLedger()
        super.init()
        notifications.delegate = self
    }
    var allowed: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }
    var nativeMonitoringEnabled: Bool { preferences.enabled && (preferences.created || preferences.ready) }
    var anyMonitoringEnabled: Bool { nativeMonitoringEnabled }
    func refreshAuthorization() async {
        let value = await notifications.notificationSettings().authorizationStatus
        if authorization != value { authorization = value }
    }
    func requestPermission() async {
        do { _ = try await notifications.requestAuthorization(options: [.alert, .sound, .badge]); await refreshAuthorization(); error = nil }
        catch { self.error = "Не удалось запросить уведомления: " + error.localizedDescription }
    }
    func configure(session: Session?, shops: [Int], demo: Bool, known: Bool, active: Bool) {
        guard !demo, let session else { if !context.isEmpty { endObservation() }; status = demo ? "Демо: реальные заказы не проверяются" : "Войди в ВВ для уведомлений"; return }
        let scope = (CourierAPI(session: session).sessionFingerprint ?? session.courierID) + ":" + Set(shops).sorted().map(String.init).joined(separator: ",")
        if context != scope {
            let oldEpoch = ledger.epoch
            generation = UUID(); pollTask?.cancel(); pollTask = nil; pending = []; freshActiveAt = .distantPast; clearForeground()
            observedShift = nil; lastCheckedAt = nil; testStatus = nil
            context = scope; error = nil
            removeExpressNotifications(epoch: oldEpoch)
        }
        if let data = try? JSONEncoder().encode(SavedScope(courierID: session.courierID, shops: shops)) { UserDefaults.standard.set(data, forKey: "express.notifications.scope.v1") }
        if known && !active { stopShift() }
    }
    func endObservation() {
        let oldEpoch = ledger.epoch
        generation = UUID(); pollTask?.cancel(); pollTask = nil; context = ""; pending = []; freshActiveAt = .distantPast; clearForeground()
        observedShift = nil; lastCheckedAt = nil; testStatus = nil; status = "Войди в ВВ для уведомлений"
        expiredCourierID = nil; destination = nil; error = nil
        ledger.endShift(); persist(); removeExpressNotifications(epoch: oldEpoch)
        UserDefaults.standard.removeObject(forKey: "express.notifications.scope.v1")
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
    }
    private func stopShift() {
        let oldEpoch = ledger.epoch
        generation = UUID(); pollTask?.cancel(); pollTask = nil
        pending = []; freshActiveAt = .distantPast; clearForeground(); observedShift = false
        status = "Смена не активна. Проверяем её, пока приложение открыто"
        if ledger.active { ledger.endShift(); persist() }
        removeExpressNotifications(epoch: oldEpoch)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
    }
    /// Disabled native notices must not leave an independent order poll running.
    func pauseDelivery() {
        let oldEpoch = ledger.epoch
        pending = []; clearForeground()
        status = "Уведомления об экспрессах выключены"
        if ledger.active { ledger.endShift(); persist() }
        removeExpressNotifications(epoch: oldEpoch)
        generation = UUID(); pollTask?.cancel(); pollTask = nil; freshActiveAt = .distantPast
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: ledgerKey); lastSave = Date() }
    }
    func poll(session: Session, shops: [Int], quiet: Bool = false, backgroundToken: UUID? = nil) async -> Bool? {
        guard anyMonitoringEnabled else { removeExpressNotifications(epoch: ledger.epoch); return nil }
        if let pollTask {
            let id = pollID
            if let backgroundToken { backgroundPolls[backgroundToken] = id }
            let result = await pollTask.value
            if let backgroundToken, backgroundPolls[backgroundToken] == id { backgroundPolls.removeValue(forKey: backgroundToken) }
            return result
        }
        let id = UUID(), owner = generation
        pollID = id
        if let backgroundToken { backgroundPolls[backgroundToken] = id }
        let task = Task { await performPoll(session: session, shops: shops, quiet: quiet, owner: owner) }
        pollTask = task
        let result = await task.value
        if let backgroundToken, backgroundPolls[backgroundToken] == id { backgroundPolls.removeValue(forKey: backgroundToken) }
        if pollID == id { pollTask = nil }
        return result
    }
    private func performPoll(session: Session, shops: [Int], quiet: Bool, owner: UUID) async -> Bool? {
        func current() -> Bool {
            let stored = SessionStore.load()
            return !Task.isCancelled && generation == owner && stored?.token == session.token && stored?.courierID == session.courierID
        }
        guard current() else { return nil }
        // Foreground notices keep working when the user has not granted iOS
        // permission. Authorization controls only the system delivery channel.
        await refreshAuthorization()
        guard current() else { return nil }
        let client = CourierAPI(session: session, shopNumbers: shops)
        do {
            let active = try await client.activeShift()
            guard current() else { return nil }
            lastCheckedAt = Date(); observedShift = active
            guard active else { stopShift(); error = nil; return false }
            async let assembly = client.feed(.assembly)
            async let ready = client.feed(.available)
            let snapshots = try await (assembly, ready)
            guard current() else { return nil }
            // A shift may have ended while a multi-page order list was loading.
            let stillActive = try await client.activeShift()
            guard current() else { return nil }
            guard stillActive else { lastCheckedAt = Date(); stopShift(); error = nil; return false }
            freshActiveAt = Date()
            lastCheckedAt = freshActiveAt; observedShift = true
            let nativeEnabled = nativeMonitoringEnabled
            if nativeEnabled {
                status = allowed ? "На смене: баннеры в приложении и системные уведомления включены" : "На смене: баннеры в приложении включены. Для звука и уведомлений вне приложения дай разрешение iPhone"
                func express(_ parcels: [Parcel]) -> [ExpressParcelReference] {
                    parcels.filter(\.express).map { ExpressParcelReference(id: $0.id, label: $0.label, shopID: $0.shopID) }
                }
                let assembling = express(snapshots.0.parcels), available = express(snapshots.1.parcels)
                let wasActive = ledger.active
                let suppressExisting = quiet || (UIApplication.shared.applicationState == .active && needsQuietResume())
                let events = ledger.observe(courierID: session.courierID, shops: shops, shiftActive: true, assembling: assembling, ready: available, suppressExisting: suppressExisting)
                pending.append(contentsOf: events.filter { preferences.allows($0.kind) })
                let currentAssembly = Set(assembling.map(\.id)), currentReady = Set(available.map(\.id))
                pending = pending.filter { event in
                    event.epoch == ledger.epoch && event.courierID == session.courierID && Date().timeIntervalSince(event.observedAt) < 120 && preferences.allows(event.kind)
                    && (event.kind == .ready ? currentReady.contains(event.parcel.id) : currentAssembly.contains(event.parcel.id) && !currentReady.contains(event.parcel.id))
                }
                let allowedKinds = Set(ExpressEventKind.allCases.filter(preferences.allows))
                inbox.update(events, courierID: session.courierID, epoch: ledger.epoch, assembling: currentAssembly, ready: currentReady, allowedKinds: allowedKinds)
                let previousIDs = Set(foregroundEvents.map(\.id))
                foregroundEvents = inbox.events
                if UIApplication.shared.applicationState == .active, foregroundEvents.contains(where: { !previousIDs.contains($0.id) }) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    if let event = foregroundEvents.last { UIAccessibility.post(notification: .announcement, argument: event.kind.title + ". Заказ " + event.parcel.label) }
                }
                if !events.isEmpty || !wasActive || Date().timeIntervalSince(lastSave) >= 60 { persist() }
            } else {
                pending = []; clearForeground()
                status = "На смене: уведомления об экспрессах выключены"
            }
            // Native foreground/system notices use the freshly confirmed shift.
            if nativeEnabled && allowed {
                let delivered = Set(await notifications.deliveredNotifications().map { $0.request.identifier })
                var failed: [ExpressOrderEvent] = []
                for event in pending {
                    guard current(), preferences.allows(event.kind), ExpressNotificationDelivery.isCurrent(courierID: event.courierID, expectedCourierID: session.courierID, epoch: event.epoch, expectedEpoch: ledger.epoch, active: ledger.active, confirmedAt: freshActiveAt, observedAt: event.observedAt) else { return nil }
                    if delivered.contains(event.id) { continue }
                    let content = UNMutableNotificationContent()
                    content.title = event.kind.title
                    content.body = "Заказ " + event.parcel.label + (event.parcel.shopID.map { " · магазин \($0)" } ?? "")
                    content.sound = .default; content.threadIdentifier = "vv.express." + session.courierID
                    content.userInfo = ["courierID": session.courierID, "parcelID": event.parcel.id, "kind": event.kind.rawValue, "epoch": event.epoch, "observedAt": event.observedAt.timeIntervalSince1970, "sessionFingerprint": client.sessionFingerprint ?? ""]
                    do {
                        try await notifications.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
                        guard current(), preferences.allows(event.kind), ledger.active, event.epoch == ledger.epoch else {
                            notifications.removePendingNotificationRequests(withIdentifiers: [event.id])
                            notifications.removeDeliveredNotifications(withIdentifiers: [event.id])
                            return nil
                        }
                    }
                    catch { guard current() else { return nil }; failed.append(event); self.error = "Не удалось показать уведомление. Проверим снова при обновлении." }
                }
                guard current() else { return nil }
                pending = failed
                if failed.isEmpty { error = nil }
            } else { pending = []; error = nil }
            guard current() else { return nil }
            scheduleBackgroundRefresh()
            return true
        } catch is CancellationError { return nil }
        catch {
            if current() {
                freshActiveAt = .distantPast; observedShift = nil; clearForeground()
                if (error as? CourierError)?.statusCode == 401 {
                    expiredCourierID = session.courierID; stopShift()
                    self.error = "Сессия ВВ завершена. Войди заново для уведомлений."
                } else { self.error = "Экспрессы сейчас не обновились. Проверка повторится после восстановления связи."; status = "Нет свежего подтверждения смены. Уведомления приостановлены" }
            }
            return nil
        }
    }
    private func clearForeground() {
        inbox.reset()
        if !foregroundEvents.isEmpty { foregroundEvents = [] }
        #if DEBUG
        uiPreviewActive = false
        #endif
    }
    #if DEBUG
    func showUIPreview(demo: Bool, session: Session?) {
        guard ExpressNotificationUIPreview.enabled(demo: demo, courierID: session?.courierID, token: session?.token), !uiPreviewPresented else { return }
        let event = ExpressNotificationUIPreview.event()
        uiPreviewPresented = true; uiPreviewActive = true
        inbox.update([event], courierID: "demo", epoch: ExpressNotificationUIPreview.epoch, assembling: [], ready: [event.parcel.id], allowedKinds: [.ready])
        foregroundEvents = inbox.events
    }
    func isUIPreviewNotice(_ event: ExpressOrderEvent) -> Bool {
        ExpressNotificationUIPreview.enabled(demo: uiPreviewActive, courierID: event.courierID, token: "offline-fixture-token")
            && event.epoch == ExpressNotificationUIPreview.epoch && event.parcel.id == ExpressNotificationUIPreview.parcelID
            && foregroundEvents.contains(where: { $0.id == event.id })
    }
    #endif
    func dismissForegroundNotice(_ id: String) {
        inbox.dismiss(id); foregroundEvents = inbox.events
    }
    func openForegroundNotice(_ event: ExpressOrderEvent, onOpen: ((ExpressNotificationTarget) -> Void)? = nil) {
        #if DEBUG
        if isUIPreviewNotice(event) {
            let target = ExpressNotificationTarget(courierID: "demo", parcelID: ExpressNotificationUIPreview.parcelID, kind: .ready)
            dismissForegroundNotice(event.id)
            if let onOpen { onOpen(target) } else { destination = target }
            return
        }
        #endif
        guard foregroundEvents.contains(where: { $0.id == event.id }), preferences.allows(event.kind),
              ExpressNotificationDelivery.isCurrent(courierID: event.courierID, expectedCourierID: SessionStore.load()?.courierID, epoch: event.epoch, expectedEpoch: ledger.epoch, active: ledger.active, confirmedAt: freshActiveAt, observedAt: event.observedAt) else { dismissForegroundNotice(event.id); return }
        let target = ExpressNotificationTarget(courierID: event.courierID, parcelID: event.parcel.id, kind: event.kind)
        dismissForegroundNotice(event.id)
        if let onOpen { onOpen(target) } else { destination = target }
    }
    /// A foreground resume after a long suspension silently baselines the
    /// current inventory instead of announcing orders whose arrival is unknown.
    func needsQuietResume() -> Bool { ExpressNotificationDelivery.needsQuietResume(lastObservedAt: ledger.lastObservedAt) }
    @discardableResult func checkNow() async -> Bool? {
        guard !context.isEmpty else { return nil }
        guard let session = SessionStore.load(),
              let data = UserDefaults.standard.data(forKey: "express.notifications.scope.v1"),
              let scope = try? JSONDecoder().decode(SavedScope.self, from: data), scope.courierID == session.courierID else {
            status = "Войди в ВВ для проверки уведомлений"; return nil
        }
        guard anyMonitoringEnabled else { pauseDelivery(); return nil }
        return await poll(session: session, shops: scope.shops, quiet: needsQuietResume())
    }
    @discardableResult func sendTestNotification() async -> Bool {
        testStatus = nil
        await refreshAuthorization()
        guard allowed else { testStatus = "Сначала разреши системные уведомления в iPhone. Баннеры приложения работают и без этого разрешения."; return false }
        guard await checkNow() == true, let session = SessionStore.load(), ledger.active,
              Date().timeIntervalSince(freshActiveAt) >= 0, Date().timeIntervalSince(freshActiveAt) <= 30 else {
            testStatus = "Для теста нужна подтверждённая активная смена ВВ. " + (error ?? status); return false
        }
        let epoch = ledger.epoch, owner = generation, observedAt = Date()
        let identifier = "vv.express.\(epoch).test.\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = "Уведомления ВВ работают"
        content.body = "Это проверка уведомлений, не новый заказ. Экспрессы будут показаны только на активной смене."
        content.sound = .default
        content.userInfo = ["courierID": session.courierID, "epoch": epoch, "test": true, "observedAt": observedAt.timeIntervalSince1970, "sessionFingerprint": CourierAPI(session: session).sessionFingerprint ?? ""]
        do {
            try await notifications.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            guard owner == generation, ledger.active, SessionStore.load()?.token == session.token else {
                notifications.removePendingNotificationRequests(withIdentifiers: [identifier]); notifications.removeDeliveredNotifications(withIdentifiers: [identifier]); return false
            }
            testStatus = "Тест передан iOS. Проверь баннер и звук; звук зависит от настроек iPhone."
            return true
        } catch { testStatus = "iPhone не принял тест: " + error.localizedDescription; return false }
    }
    var backgroundExplanation: String {
        UIApplication.shared.backgroundRefreshStatus == .available
            ? "В фоне iOS сама выбирает время проверки и может не дать её выполнить. Мгновенная доставка при закрытом приложении не подключена."
            : "Фоновое обновление запрещено в iPhone. Проверки работают, пока приложение открыто."
    }
    private func removeExpressNotifications(epoch: String) {
        let cutoff = Date()
        let prefix = "vv.express.\(epoch)."
        Task {
            let requests = await notifications.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
            notifications.removePendingNotificationRequests(withIdentifiers: requests)
            let delivered = await notifications.deliveredNotifications().filter { $0.request.identifier.hasPrefix(prefix) && $0.date <= cutoff }.map { $0.request.identifier }
            notifications.removeDeliveredNotifications(withIdentifiers: delivered)
        }
    }
    func registerBackgroundRefresh() {
        guard !registered else { return }; registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundID, using: nil) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let backgroundToken = UUID()
            let work = Task { @MainActor [weak self] in
                guard let self else { task.setTaskCompleted(success: false); return }
                self.scheduleBackgroundRefresh()
                guard let session = SessionStore.load(),
                      let data = UserDefaults.standard.data(forKey: "express.notifications.scope.v1"),
                      let scope = try? JSONDecoder().decode(SavedScope.self, from: data), scope.courierID == session.courierID else { task.setTaskCompleted(success: true); return }
                await self.refreshAuthorization()
                guard self.nativeMonitoringEnabled && self.allowed else { task.setTaskCompleted(success: true); return }
                self.configure(session: session, shops: scope.shops, demo: false, known: false, active: false)
                let result = await self.poll(session: session, shops: scope.shops, backgroundToken: backgroundToken)
                self.persist(); self.scheduleBackgroundRefresh(); task.setTaskCompleted(success: result != nil)
            }
            task.expirationHandler = { [weak self] in
                work.cancel()
                Task { @MainActor in
                    guard let self, let id = self.backgroundPolls.removeValue(forKey: backgroundToken), self.pollID == id else { return }
                    self.pollTask?.cancel()
                }
            }
        }
    }
    func scheduleBackgroundRefresh() {
        #if DEBUG
        guard !uiPreviewActive else { return }
        #endif
        let nativeBackground = nativeMonitoringEnabled && allowed && ledger.active
        guard nativeBackground,
              UIApplication.shared.backgroundRefreshStatus == .available else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let info = notification.request.content.userInfo
            let session = SessionStore.load()
            let courier = info["courierID"] as? String ?? ""
            let kind = (info["kind"] as? String).flatMap(ExpressEventKind.init(rawValue:))
            let isTest = info["test"] as? Bool == true
            let valid = ExpressNotificationDelivery.isCurrent(courierID: courier, expectedCourierID: session?.courierID, epoch: info["epoch"] as? String ?? "", expectedEpoch: self.ledger.epoch, active: self.ledger.active, confirmedAt: self.freshActiveAt, observedAt: Date(timeIntervalSince1970: info["observedAt"] as? TimeInterval ?? 0))
                && info["sessionFingerprint"] as? String == CourierAPI(session: session).sessionFingerprint
                && notification.request.identifier.hasPrefix("vv.express.\(self.ledger.epoch).")
                && (isTest ? self.preferences.enabled : kind.map(self.preferences.allows) == true)
            // The app has its own visible order banner; avoid two simultaneous
            // banners for one event. An explicit test demonstrates iOS delivery.
            completionHandler(valid ? (isTest ? [.banner, .sound, .list] : [.sound, .list]) : [])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            defer { completionHandler() }
            let info = response.notification.request.content.userInfo
            guard let courier = info["courierID"] as? String, courier == SessionStore.load()?.courierID,
                  info["epoch"] as? String == self.ledger.epoch, self.ledger.active,
                  info["sessionFingerprint"] as? String == CourierAPI(session: SessionStore.load()).sessionFingerprint,
                  let parcel = info["parcelID"] as? String, !parcel.isEmpty,
                  let rawKind = info["kind"] as? String, let kind = ExpressEventKind(rawValue: rawKind) else { return }
            self.destination = ExpressNotificationTarget(courierID: courier, parcelID: parcel, kind: kind)
        }
    }
}

@MainActor struct ExpressNotificationMonitoring: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var center = ExpressNotificationCenter.shared
    @StateObject private var preferences = ExpressNotificationPreferences.shared
    private var key: String { "\(model.shopScopeKey):\(model.active):\(model.shiftKnown):\(model.sessionExpired):\(phase == .active):\(preferences.enabled):\(preferences.created):\(preferences.ready)" }
    func body(content: Content) -> some View {
        content.task(id: key) {
            #if DEBUG
            if ExpressNotificationUIPreview.enabled(demo: model.demo, courierID: model.session?.courierID, token: model.session?.token) {
                if phase == .active { center.showUIPreview(demo: model.demo, session: model.session) }
                return
            }
            #endif
            let owner = model.identity
            center.configure(session: model.sessionExpired ? nil : model.session, shops: model.api.shopNumbers, demo: model.demo, known: model.shiftKnown, active: model.active)
            if !preferences.enabled || (!preferences.created && !preferences.ready) { center.pauseDelivery() }
            guard phase == .active, !model.demo, let session = model.session, !model.sessionExpired,
                  center.anyMonitoringEnabled else { return }
            await center.refreshAuthorization()
            var quiet = center.needsQuietResume(), failures = 0
            while !Task.isCancelled && model.identity == owner {
                let activity = model.activityObservation()
                if let active = await center.poll(session: session, shops: model.api.shopNumbers, quiet: quiet) {
                    guard !Task.isCancelled, model.identity == owner else { return }
                    quiet = false; failures = 0
                    model.observeNativeActivity(active, ifCurrent: activity)
                } else {
                    guard !Task.isCancelled, model.identity == owner else { return }
                    failures = min(4, failures + 1)
                    if center.observedShift == nil && model.shiftKnown { model.observeNativeActivity(nil, ifCurrent: activity) }
                }
                do { try await Task.sleep(nanoseconds: UInt64(min(120, 20 * max(1, failures))) * 1_000_000_000) } catch { return }
            }
        }
        .onChange(of: phase) { _, value in if value != .active { center.scheduleBackgroundRefresh() } }
        .onChange(of: center.destination) { _, value in route(value) }
        .onChange(of: center.expiredCourierID) { _, value in if let value, model.session?.courierID == value { model.sessionExpired = true } }
        .onAppear { route(center.destination) }
    }
    private func route(_ target: ExpressNotificationTarget?) {
        #if DEBUG
        if let target, ExpressNotificationUIPreview.enabled(demo: model.demo, courierID: model.session?.courierID, token: model.session?.token), target.courierID == "demo", target.parcelID == ExpressNotificationUIPreview.parcelID, target.kind == .ready {
            model.tab = 0; model.selectedFeed = .available; model.notificationTarget = target; center.destination = nil
            return
        }
        #endif
        guard let target, !model.demo, model.session?.courierID == target.courierID else { return }
        model.tab = 0; model.selectedFeed = target.kind == .ready ? .available : .assembly
        model.notificationTarget = target; center.destination = nil
    }
}

struct ExpressNotificationSettingsView: View {
    @StateObject private var preferences = ExpressNotificationPreferences.shared
    @StateObject private var center = ExpressNotificationCenter.shared
    @State private var checking = false
    @State private var testing = false
    var body: some View {
        CourierPage("Уведомления") {
            CourierCard {
                Toggle("Уведомления об экспрессах", isOn: $preferences.enabled).accessibilityIdentifier("notifications.enabled")
                Toggle("Оформлен экспресс", isOn: $preferences.created).disabled(!preferences.enabled)
                Toggle("Экспресс готов", isOn: $preferences.ready).disabled(!preferences.enabled)
                Text("Только во время активной смены ВВ и для выбранных магазинов.").font(.caption).foregroundStyle(Palette.muted)
            }
            CourierCard("Разрешение iPhone") {
                Text(center.allowed ? "Уведомления разрешены" : center.authorization == .denied ? "Уведомления выключены в iPhone" : "Разрешение ещё не запрошено").font(.subheadline)
                if center.authorization == .notDetermined {
                    Button("Разрешить уведомления") { Task { await center.requestPermission() } }.buttonStyle(CourierButtonStyle(primary: true))
                } else if !center.allowed {
                    Button("Открыть настройки iPhone") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(CourierButtonStyle())
                }
            }
            CourierCard {
                Text(center.status).font(.subheadline).accessibilityIdentifier("notifications.status")
                if let checked = center.lastCheckedAt { Text("Последняя проверка: " + checked.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(Palette.muted) }
                Button(checking ? "Проверяем…" : "Проверить сейчас") {
                    checking = true
                    Task { await center.checkNow(); checking = false }
                }.buttonStyle(CourierButtonStyle()).disabled(checking || testing).accessibilityIdentifier("notifications.check")
                Button(testing ? "Отправляем тест…" : "Проверить баннер и звук iPhone") {
                    testing = true
                    Task { await center.sendTestNotification(); testing = false }
                }.buttonStyle(CourierButtonStyle()).disabled(checking || testing || !center.allowed || !preferences.enabled).accessibilityIdentifier("notifications.test")
                if let result = center.testStatus { Text(result).font(.caption).accessibilityIdentifier("notifications.test.result") }
                Text("В открытом приложении проверяем смену и новые экспрессы примерно каждые 20 секунд. Баннеры приложения работают без системного разрешения. Первый список после входа или долгого перерыва загружается тихо.").font(.caption).foregroundStyle(Palette.muted)
                Text(center.backgroundExplanation).font(.caption).foregroundStyle(Palette.muted)
                if let error = center.error { Text(error).font(.caption).foregroundStyle(Palette.warning) }
            }
        }.task { await center.refreshAuthorization() }.accessibilityIdentifier("notifications.settings")
    }
}
