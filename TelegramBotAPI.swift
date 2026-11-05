import Foundation

enum TelegramBotError: LocalizedError, Equatable {
    case invalidToken
    case invalidDestination
    case rejected(code: Int, retryAfter: Int?)
    case uncertain
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidToken: return "Токен Telegram-бота неверен. Проверь токен из BotFather."
        case .invalidDestination: return "Укажи @имя группы, числовой chat ID или ссылку t.me на сообщение. Для темы нужен положительный номер. Пригласительная ссылка не содержит chat ID."
        case .rejected(let code, let retryAfter):
            if code == 409 { return "У бота уже включён webhook или другой опрос. Поиск групп недоступен: укажи chat ID вручную. Другой опрос и webhook не изменены." }
            if code == 429 { return retryAfter.map { "Telegram ограничил частоту запросов. Повтори через \($0) с." } ?? "Telegram ограничил частоту запросов. Повтори позже." }
            if code == 403 { return "Боту запрещён доступ. Добавь его в нужную группу и разреши отправлять сообщения." }
            return "Telegram отклонил запрос (код \(code)). Проверь группу, тему и права бота."
        case .uncertain: return "Подтверждение Telegram не получено. Сообщение могло уйти; автоматически повторять его нельзя. Проверь чат перед повтором."
        case .invalidResponse: return "Не удалось прочитать ответ Telegram. Проверь интернет и повтори проверку."
        }
    }
}

struct TelegramBotIdentity: Codable, Equatable {
    let id: Int64
    let username: String
    let name: String
}

struct TelegramChatIdentity: Codable, Equatable {
    let id: Int64
    let title: String
    let type: String
}

struct TelegramChatDestination: Codable, Equatable {
    var chatID: String
    var threadID: Int?

    init(chatID: String, threadID: Int? = nil) { self.chatID = chatID; self.threadID = threadID }

    static func parse(input: String, threadInput: String = "") throws -> TelegramChatDestination {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitThread = threadInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = explicitThread.isEmpty ? nil : try positiveInteger(explicitThread)
        guard !value.isEmpty else { throw TelegramBotError.invalidDestination }
        if value.first == "@" { return TelegramChatDestination(chatID: try username(String(value.dropFirst())), threadID: thread) }
        let numeric = value.first == "-" ? String(value.dropFirst()) : value
        if asciiDigits(numeric), let id = Int64(value), id != 0 { return TelegramChatDestination(chatID: String(id), threadID: thread) }

        let address = value.contains("://") ? value : "https://" + value
        guard let url = URLComponents(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["t.me", "www.t.me", "telegram.me", "www.telegram.me"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { throw TelegramBotError.invalidDestination }
        var path = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if path.first == "s" { path.removeFirst() }
        guard let first = path.first else { throw TelegramBotError.invalidDestination }
        var linkedThread: Int?
        if let raw = url.queryItems?.first(where: { $0.name == "thread" })?.value { linkedThread = try positiveInteger(raw) }
        if first == "c" {
            guard path.count == 3 || path.count == 4,
                  asciiDigits(path[1]), let internalID = Int64(path[1]), internalID > 0,
                  let id = Int64("-100" + String(internalID)) else { throw TelegramBotError.invalidDestination }
            for part in path.dropFirst(2) { _ = try positiveInteger(part) }
            if path.count == 4 { linkedThread = try positiveInteger(path[2]) }
            return TelegramChatDestination(chatID: String(id), threadID: thread ?? linkedThread)
        }
        guard !["joinchat", "addlist", "share", "login", "proxy", "socks"].contains(first.lowercased()), path.count <= 3 else { throw TelegramBotError.invalidDestination }
        let chat = try username(first)
        for part in path.dropFirst() { _ = try positiveInteger(part) }
        if path.count == 3 { linkedThread = try positiveInteger(path[1]) }
        return TelegramChatDestination(chatID: chat, threadID: thread ?? linkedThread)
    }

    private static func asciiDigits(_ value: String) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } }
    private static func positiveInteger(_ value: String) throws -> Int {
        guard asciiDigits(value), let result = Int(value), result > 0 else { throw TelegramBotError.invalidDestination }
        return result
    }
    private static func username(_ value: String) throws -> String {
        guard let first = value.utf8.first, (65...90).contains(first) || (97...122).contains(first), value.utf8.count <= 32,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { throw TelegramBotError.invalidDestination }
        return "@" + value
    }
}

/// This client knows only the bot token. No courier session or credentials are
/// accepted here. A send is attempted once; an unconfirmed result is uncertain.
struct TelegramBotAPI {
    private let token: String
    private let session: URLSession
    private static let redirectBlocker = TelegramRedirectBlocker()

    init(token: String, session: URLSession = .shared) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func getMe() async throws -> TelegramBotIdentity {
        let user: BotUser = try await request("getMe", body: [:])
        guard user.id > 0, user.isBot else { throw TelegramBotError.invalidResponse }
        let name = [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return TelegramBotIdentity(id: user.id, username: user.username ?? "", name: name.isEmpty ? "Бот" : name)
    }

    func getChat(_ destination: TelegramChatDestination) async throws -> TelegramChatIdentity {
        let target = try validated(destination)
        let chat: Chat = try await request("getChat", body: ["chat_id": target.chatID])
        return try chat.identity()
    }

    func sendMessage(to destination: TelegramChatDestination, text: String) async throws {
        let target = try validated(destination)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 4096 else { throw TelegramBotError.rejected(code: 400, retryAfter: nil) }
        var body: [String: Any] = ["chat_id": target.chatID, "text": text]
        if let thread = target.threadID { body["message_thread_id"] = thread }
        let message: SentMessage = try await request("sendMessage", body: body, sending: true)
        guard message.messageID > 0 else { throw TelegramBotError.uncertain }
    }

    /// Read group metadata without acknowledging any updates or changing the
    /// other consumer's allowed_updates/webhook. Message text is not decoded.
    func discoverChats() async throws -> [TelegramChatIdentity] {
        let updates: [ChatUpdate] = try await request("getUpdates", body: ["timeout": 0])
        var order: [Int64] = [], found: [Int64: TelegramChatIdentity] = [:]
        for update in updates {
            for chat in [update.message?.chat, update.membership?.chat].compactMap({ $0 }) where chat.type == "group" || chat.type == "supergroup" {
                let identity = try chat.identity()
                if found[identity.id] == nil { order.append(identity.id) }
                found[identity.id] = identity
            }
        }
        return order.compactMap { found[$0] }
    }

    private func validated(_ destination: TelegramChatDestination) throws -> TelegramChatDestination {
        try TelegramChatDestination.parse(input: destination.chatID, threadInput: destination.threadID.map(String.init) ?? "")
    }
    private func request<Result: Decodable>(_ method: String, body: [String: Any], sending: Bool = false) async throws -> Result {
        try Task.checkCancellation()
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let botID = Int64(parts[0]), botID > 0, (20...128).contains(parts[1].utf8.count),
              parts[1].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
              let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw TelegramBotError.invalidToken }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"; request.httpShouldHandleCookies = false
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: Self.redirectBlocker) }
        catch {
            if sending { throw TelegramBotError.uncertain }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw TelegramBotError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == "api.telegram.org" else { throw sending ? TelegramBotError.uncertain : TelegramBotError.invalidResponse }
        let status = try? JSONDecoder().decode(APIStatus.self, from: data)
        let retryAfter = [status?.parameters?.retryAfter, http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)].compactMap { $0 }.first { $0 > 0 }
        if http.statusCode == 401 { throw TelegramBotError.invalidToken }
        if http.statusCode == 429 { throw TelegramBotError.rejected(code: 429, retryAfter: retryAfter) }
        if status?.ok == false, let code = status?.errorCode, code > 0 {
            if code == 401 { throw TelegramBotError.invalidToken }
            throw TelegramBotError.rejected(code: code, retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            if sending && !(400..<500).contains(http.statusCode) { throw TelegramBotError.uncertain }
            throw TelegramBotError.rejected(code: http.statusCode, retryAfter: retryAfter)
        }
        guard status?.ok == true, let result = try? JSONDecoder().decode(APIResult<Result>.self, from: data).result else { throw sending ? TelegramBotError.uncertain : TelegramBotError.invalidResponse }
        return result
    }

    private struct APIStatus: Decodable {
        let ok: Bool
        let errorCode: Int?
        let parameters: Parameters?
        enum CodingKeys: String, CodingKey { case ok, parameters; case errorCode = "error_code" }
    }
    private struct Parameters: Decodable {
        let retryAfter: Int?
        enum CodingKeys: String, CodingKey { case retryAfter = "retry_after" }
    }
    private struct APIResult<Result: Decodable>: Decodable { let result: Result }
    private struct BotUser: Decodable {
        let id: Int64; let isBot: Bool; let username: String?; let firstName: String?; let lastName: String?
        enum CodingKeys: String, CodingKey { case id, username; case isBot = "is_bot"; case firstName = "first_name"; case lastName = "last_name" }
    }
    private struct Chat: Decodable {
        let id: Int64; let type: String; let title: String?; let username: String?; let firstName: String?; let lastName: String?
        enum CodingKeys: String, CodingKey { case id, type, title, username; case firstName = "first_name"; case lastName = "last_name" }
        func identity() throws -> TelegramChatIdentity {
            guard id != 0, ["private", "group", "supergroup", "channel"].contains(type) else { throw TelegramBotError.invalidResponse }
            let name = [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return TelegramChatIdentity(id: id, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? (name.isEmpty ? username.map { "@" + $0 } ?? String(id) : name), type: type)
        }
    }
    private struct ChatUpdate: Decodable {
        let message: ChatContainer?; let membership: ChatContainer?
        enum CodingKeys: String, CodingKey { case message; case membership = "my_chat_member" }
    }
    private struct ChatContainer: Decodable { let chat: Chat }
    private struct SentMessage: Decodable {
        let messageID: Int64
        enum CodingKeys: String, CodingKey { case messageID = "message_id" }
    }
}

private final class TelegramRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
