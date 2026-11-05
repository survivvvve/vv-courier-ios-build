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
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        created = defaults.object(forKey: Key.created) as? Bool ?? true
        ready = defaults.object(forKey: Key.ready) as? Bool ?? true
        onlyExpress = defaults.object(forKey: Key.onlyExpress) as? Bool ?? false
        if let data = defaults.data(forKey: Key.configuration),
           let value = try? JSONDecoder().decode(TelegramNotificationConfiguration.self, from: data),
           value.botID > 0, !value.botUsername.isEmpty, !value.chat.chatID.isEmpty,
           value.chat.threadID.map({ $0 > 0 }) ?? true {
            configuration = value
        }
    }

    /// The secret is never copied into UserDefaults or included in configuration.
    var token: String? { TelegramNotificationTokenStore.read() }
    var isConfigured: Bool { configuration != nil && token != nil }
    var monitoringEnabled: Bool { enabled && isConfigured && (created || ready) }

    func save(token: String, bot: TelegramBotIdentity, chat: TelegramChatIdentity, threadID: Int? = nil) throws {
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw TelegramNotificationPreferenceError("Введи токен бота из BotFather.") }
        guard bot.id > 0, !bot.username.isEmpty, chat.id != 0, threadID.map({ $0 > 0 }) ?? true else {
            throw TelegramNotificationPreferenceError("Не удалось сохранить бота или чат. Проверь подключение ещё раз.")
        }
        let value = TelegramNotificationConfiguration(botID: bot.id, botUsername: bot.username,
            chat: TelegramChatDestination(chatID: String(chat.id), threadID: threadID), chatTitle: chat.title)
        let encoded = try JSONEncoder().encode(value)
        try TelegramNotificationTokenStore.write(secret)
        defaults.set(encoded, forKey: Key.configuration)
        configuration = value
        storageError = nil
        updatingConfiguration = true
        enabled = true
        updatingConfiguration = false
        revision &+= 1
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
