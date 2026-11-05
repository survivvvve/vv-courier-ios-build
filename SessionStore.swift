import Foundation
import Security

enum SessionStore {
    private static let service = "ru.local.vvcourier.ios.session"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "courier"]
    }
    static func load() -> Session? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        guard let session = try? JSONDecoder().decode(Session.self, from: data), !session.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.courierID.isEmpty else { return nil }
        return session
    }
    static func save(_ session: Session) throws {
        guard !session.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.courierID.isEmpty else { throw CourierError(message: "ВВ не сообщил действующий вход.") }
        let data = try JSONEncoder().encode(session)
        let attributes = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            attributes.forEach { request[$0.key] = $0.value }
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw CourierError(message: "Не удалось сохранить вход в Keychain.") }
        } else if status != errSecSuccess { throw CourierError(message: "Не удалось обновить вход в Keychain.") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}
