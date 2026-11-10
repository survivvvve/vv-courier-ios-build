import Foundation

/// Plain text batches are bounded in UTF-16 units, below Telegram's limit even
/// when an event includes emoji. No order addresses or customer notes enter it.
struct TelegramNotificationBatch {
    let eventIDs: [String]
    let text: String
    static func make(_ events: [TelegramOrderEvent], limit: Int = 3500) -> [TelegramNotificationBatch] {
        var batches: [TelegramNotificationBatch] = [], ids: [String] = [], text = ""
        let cap = max(1, min(3500, limit))
        func append() {
            if !ids.isEmpty { batches.append(TelegramNotificationBatch(eventIDs: ids, text: text)) }
            ids = []; text = ""
        }
        for event in events {
            var message = event.messageText
            if message.utf16.count > cap {
                message = ""
                for character in event.messageText {
                    let next = message + String(character)
                    if next.utf16.count > cap { break }
                    message = next
                }
            }
            guard !message.isEmpty else { continue }
            let next = text.isEmpty ? message : text + "\n\n" + message
            if next.utf16.count > cap { append() }
            text = text.isEmpty ? message : text + "\n\n" + message
            ids.append(event.id)
        }
        append()
        return batches
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Delivery is fed only by ExpressNotificationCenter's already completed VV
/// snapshots. It owns no VV polling task, login, server or background audio.
@MainActor final class TelegramNotificationCenter: ObservableObject {
    // Defense in depth for old saved configuration or a stale direct caller.
    // Express monitoring no longer constructs or calls this integration.
    private static let integrationEnabled = false
    static let shared = TelegramNotificationCenter()
    @Published private(set) var status = "Интеграция Telegram отключена"
    @Published private(set) var lastSentAt: Date?
    private let preferences: TelegramNotificationPreferences
    private let defaults: UserDefaults
    private let sessionProvider: () -> Session?
    private let sender: (String, TelegramChatDestination, String) async throws -> Void
    private let storageKey = "telegram.notifications.delivery.v1"
    private var ledger: TelegramOrderLedger
    private var attempted: [String: Date]
    private var savedFingerprint: String
    private var context = ""
    private var generation = UUID()
    private var needsBaseline = true
    private var blockedRevision: Int?
    private var nextAllowedAt = Date.distantPast

    private struct SavedState: Codable {
        let ledger: TelegramOrderLedger
        let attempted: [String: Date]
        let fingerprint: String
        let lastSentAt: Date?
    }
    init(defaults: UserDefaults = .standard, preferences: TelegramNotificationPreferences? = nil,
         sessionProvider: @escaping () -> Session? = { SessionStore.load() },
         sender: @escaping (String, TelegramChatDestination, String) async throws -> Void = { token, chat, text in
             _ = try await TelegramBotAPI(token: token).sendMessage(to: chat, text: text)
         }) {
        self.defaults = defaults; self.preferences = preferences ?? .shared
        self.sessionProvider = sessionProvider; self.sender = sender
        ledger = TelegramOrderLedger()
        attempted = [:]
        savedFingerprint = ""
        defaults.removeObject(forKey: storageKey)
    }
    var active: Bool { ledger.active }
    var monitoringEnabled: Bool { Self.integrationEnabled && preferences.monitoringEnabled }
    func needsQuietResume(at date: Date = Date()) -> Bool {
        needsBaseline || ExpressNotificationDelivery.needsQuietResume(lastObservedAt: ledger.lastObservedAt, at: date)
    }
    private func configurationKey() -> String {
        guard let config = preferences.configuration else { return "unconfigured" }
        return "\(config.botID)|\(config.chat.chatID)|\(config.chat.threadID.map(String.init) ?? "")|\(preferences.revision)"
    }
    func configure(session: Session?, shops: [Int], demo: Bool, known: Bool, active: Bool) {
        guard Self.integrationEnabled else { endObservation(reason: "Интеграция Telegram отключена"); return }
        guard !demo, let session else {
            endObservation(reason: demo ? "Демо: бот не получает реальные заказы" : "Войди в ВВ для отправки заказов")
            return
        }
        guard preferences.monitoringEnabled else {
            pauseDelivery(reason: preferences.isConfigured ? "Бот в Telegram выключен" : "Настрой бота и чат в Telegram")
            return
        }
        let fingerprint = (CourierAPI(session: session).sessionFingerprint ?? session.courierID) + ":" + Set(shops).sorted().map(String.init).joined(separator: ",")
        let key = fingerprint + "|" + configurationKey()
        if context != key {
            generation = UUID(); context = key; needsBaseline = true
            blockedRevision = nil; nextAllowedAt = .distantPast
            if savedFingerprint != fingerprint { ledger.endShift() }
            savedFingerprint = fingerprint
            persist()
            status = "Первая проверка загрузит текущие заказы тихо"
        }
        if known && !active { stopShift() }
    }
    func endObservation(reason: String = "Войди в ВВ для отправки заказов") {
        generation = UUID(); context = ""; needsBaseline = true; blockedRevision = nil
        nextAllowedAt = .distantPast; ledger.endShift(); savedFingerprint = ""
        status = reason; persist()
    }
    func stopShift() {
        generation = UUID(); needsBaseline = true
        if ledger.active { ledger.endShift(); persist() }
        status = "Смена не активна: отправка заказов приостановлена"
    }
    func pauseDelivery(reason: String = "Бот в Telegram выключен") {
        generation = UUID(); context = ""; needsBaseline = true
        if ledger.active { ledger.endShift(); persist() }
        status = reason
    }
    func suspend(_ reason: String) { status = reason }
    private func persist() {
        if attempted.count > 6000 {
            attempted = Dictionary(uniqueKeysWithValues: attempted.sorted { $0.value > $1.value }.prefix(4000).map { ($0.key, $0.value) })
        }
        let saved = SavedState(ledger: ledger, attempted: attempted, fingerprint: savedFingerprint, lastSentAt: lastSentAt)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: storageKey) }
    }
    private func allows(_ kind: ExpressEventKind) -> Bool {
        preferences.monitoringEnabled && (kind == .created ? preferences.created : preferences.ready)
    }
    private func matches(_ session: Session) -> Bool {
        let stored = sessionProvider()
        return stored?.courierID == session.courierID && stored?.token == session.token
    }
    /// Returns false only when a fresh VV check observes a closed shift.
    /// VV errors propagate to the existing shared polling coordinator.
    func consume(session: Session, shops: [Int], assembling: [Parcel], ready: [Parcel], quiet: Bool,
                 confirmedAt: Date, isCurrent: () -> Bool,
                 confirmActive: () async throws -> Bool) async throws -> Bool {
        guard Self.integrationEnabled, preferences.monitoringEnabled, !context.isEmpty, matches(session), isCurrent(), !Task.isCancelled else { return true }
        let owner = generation, revision = preferences.revision, configKey = configurationKey()
        func current() -> Bool {
            !Task.isCancelled && generation == owner && preferences.revision == revision && configurationKey() == configKey
                && preferences.monitoringEnabled && matches(session) && isCurrent()
        }
        guard current(), let config = preferences.configuration, let token = preferences.token else { return true }
        func record(_ parcel: Parcel) -> TelegramOrderRecord {
            TelegramOrderRecord(id: parcel.id, label: String(parcel.fullNumber.suffix(5)), shopID: parcel.shopID,
                                weight: finiteNumber(parcel.raw["weight"]), reward: finiteNumber(parcel.raw["reward"] ?? parcel.raw["courier_profit_sum"]), express: parcel.express)
        }
        let now = Date()
        let suppress = quiet || needsQuietResume(at: now)
        let events = ledger.observe(courierID: session.courierID, shops: shops, shiftActive: true,
                                    assembling: assembling.map(record), ready: ready.map(record), onlyExpress: preferences.onlyExpress,
                                    suppressExisting: suppress, at: now)
        needsBaseline = false
        // Persist the observed inventory before any send. A terminated app or
        // uncertain write must not rediscover and resend the same inventory.
        persist()
        let eligible = events.filter { allows($0.kind) && attempted[$0.id] == nil }
        guard !eligible.isEmpty else {
            if blockedRevision != revision && now >= nextAllowedAt { status = "На смене: ждём новые заказы для Telegram" }
            return true
        }
        guard blockedRevision != revision, now >= nextAllowedAt else { return true }
        for batch in TelegramNotificationBatch.make(eligible) {
            guard current(), ledger.active else { return true }
            let freshness = Date().timeIntervalSince(confirmedAt)
            guard freshness >= 0, freshness < 120 else {
                status = "Нет свежего подтверждения смены: отправка приостановлена"; return true
            }
            // This is a fresh activeShift read immediately before each Telegram
            // write, using the same session and shared polling cycle.
            guard try await confirmActive() else { stopShift(); return false }
            guard current(), ledger.active, batch.eventIDs.allSatisfy({ attempted[$0] == nil }) else { return true }
            let sendDate = Date()
            for id in batch.eventIDs { attempted[id] = sendDate }
            persist()
            do {
                try await sender(token, config.chat, batch.text)
                guard current() else { return true }
                lastSentAt = Date(); status = "Заказы отправлены в Telegram"; persist()
            } catch is CancellationError {
                if current() { status = "Отправка прервана. Повтор автоматически не выполняется" }
                return true
            } catch {
                guard current() else { return true }
                switch error {
                case TelegramBotError.invalidToken:
                    blockedRevision = revision; status = "Telegram отклонил токен. Проверь настройки бота"
                case TelegramBotError.invalidDestination:
                    blockedRevision = revision; status = "Telegram не принимает выбранный чат. Проверь настройки"
                case TelegramBotError.rejected(let code, let retryAfter):
                    if code == 429 {
                        nextAllowedAt = Date().addingTimeInterval(TimeInterval(max(1, min(retryAfter ?? 60, 86400))))
                        status = "Telegram ограничил отправки. Старые события повторно не отправляются"
                    } else {
                        if [400, 401, 403].contains(code) { blockedRevision = revision }
                        status = "Telegram отклонил отправку (\(code)). Проверь бота и чат"
                    }
                default:
                    status = "Ответ Telegram не получен. Сообщение могло уйти; автоматически не повторяем"
                }
                return true
            }
        }
        return true
    }
}

/// Keeps the settings screen's delivery status live across native destinations.
struct TelegramNotificationStatusView: View {
    @ObservedObject private var center = TelegramNotificationCenter.shared
    var body: some View { TelegramNotificationSettingsView(deliveryStatus: center.status, lastSentAt: center.lastSentAt) }
}
#endif
