import Foundation
import Combine
import Security

struct TelegramNotificationConfiguration: Codable, Equatable {
    let botID: Int64
    let botUsername: String
    let chat: TelegramChatDestination
    let chatTitle: String
}

@MainActor final class TelegramNotificationPreferences: ObservableObject {
    static let shared = TelegramNotificationPreferences()

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled); if oldValue != enabled && !updatingConfiguration { revision &+= 1 } } }
    @Published var created: Bool { didSet { defaults.set(created, forKey: Key.created); if oldValue != created { revision &+= 1 } } }
    @Published var ready: Bool { didSet { defaults.set(ready, forKey: Key.ready); if oldValue != ready { revision &+= 1 } } }
    @Published var onlyExpress: Bool { didSet { defaults.set(onlyExpress, forKey: Key.onlyExpress); if oldValue != onlyExpress { revision &+= 1 } } }
    @Published private(set) var configuration: TelegramNotificationConfiguration?
    @Published private(set) var revision = 0
    @Published private(set) var storageError: String?

    private let defaults: UserDefaults
    private var updatingConfiguration = false
    private enum Key {
        static let enabled = "telegram.notifications.v1.enabled"
        static let created = "telegram.notifications.v1.created"
        static let ready = "telegram.notifications.v1.ready"
        static let onlyExpress = "telegram.notifications.v1.onlyExpress"
        static let configuration = "telegram.notifications.v1.configuration"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Integration was removed. An upgrade must never revive an old enabled
        // destination; only Telegram's own local settings and credential change.
        enabled = false
        created = true
        ready = true
        onlyExpress = false
        defaults.set(false, forKey: Key.enabled)
        for key in [Key.created, Key.ready, Key.onlyExpress, Key.configuration] { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: "telegram.notifications.delivery.v1")
        _ = TelegramNotificationTokenStore.delete()
    }

    /// The secret is never copied into UserDefaults or included in configuration.
    var token: String? { nil }
    var isConfigured: Bool { false }
    var monitoringEnabled: Bool { false }

    func save(token: String, bot: TelegramBotIdentity, chat: TelegramChatIdentity, threadID: Int? = nil) throws {
        throw TelegramNotificationPreferenceError("Интеграция Telegram отключена в этой версии приложения.")
    }

    /// Disconnects this iPhone only. No Telegram or VV requests are made.
    func clear() {
        updatingConfiguration = true
        enabled = false
        updatingConfiguration = false
        configuration = nil
        defaults.removeObject(forKey: Key.configuration)
        let status = TelegramNotificationTokenStore.delete()
        storageError = (status == errSecSuccess || status == errSecItemNotFound) ? nil
            : "Уведомления отключены. iPhone не смог удалить токен из связки ключей; повтори отключение после разблокировки."
        revision &+= 1
    }
}

private struct TelegramNotificationPreferenceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum TelegramNotificationTokenStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ru.local.vvcourier.ios.telegram-notifications",
         kSecAttrAccount as String: "bot-token",
         kSecAttrSynchronizable as String: false]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func write(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            attributes.forEach { request[$0.key] = $0.value }
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
                throw TelegramNotificationPreferenceError("Не удалось сохранить токен на iPhone. Разблокируй устройство и повтори подключение.")
            }
        } else if status != errSecSuccess {
            throw TelegramNotificationPreferenceError("Не удалось обновить токен на iPhone. Прежнее подключение сохранено.")
        }
    }

    static func delete() -> OSStatus { SecItemDelete(query as CFDictionary) }
}
