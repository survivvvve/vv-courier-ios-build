import SwiftUI

struct TelegramNotificationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var preferences = TelegramNotificationPreferences.shared
    var deliveryStatus: String? = nil
    var lastSentAt: Date? = nil

    @State private var tokenInput = ""
    @State private var destinationInput = ""
    @State private var threadInput = ""
    @State private var chats: [TelegramChatIdentity] = []
    @State private var verifiedBot: String?
    @State private var status: String?
    @State private var failure: String?
    @State private var working = false
    @State private var work: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var disconnectPresented = false
    @State private var clearingSavedToken = false

    var body: some View {
        CourierPage("Telegram", subtitle: "Уведомления через твоего бота") {
            CourierCard {
                Text("Работает с текущей сессией ВВ. В открытом приложении проверка примерно каждые 20 секунд. При блокировке iOS может приостановить проверку.")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if model.demo { Text("В деморежиме отправка уведомлений отключена.").font(.caption).foregroundStyle(Palette.warning) }
            }
            if let configuration = preferences.configuration {
                CourierCard("Подключение") {
                    Label("@\(configuration.botUsername)", systemImage: "paperplane")
                    Text(configuration.chatTitle.isEmpty ? configuration.chat.chatID : configuration.chatTitle).font(.subheadline)
                    if let thread = configuration.chat.threadID { Text("Тема: \(thread)").font(.caption).foregroundStyle(Palette.muted) }
                    if !preferences.isConfigured { Text("Токен недоступен. Разблокируй iPhone или подключи бота заново.").font(.caption).foregroundStyle(Palette.warning) }
                    Toggle("Уведомления включены", isOn: $preferences.enabled)
                        .disabled(!preferences.isConfigured).accessibilityIdentifier("telegram.enabled")
                    Button("Отправить проверку") { sendTest() }
                        .buttonStyle(CourierButtonStyle()).disabled(working || model.demo || !preferences.isConfigured || model.session == nil)
                        .accessibilityIdentifier("telegram.test")
                    Button("Отключить бота на этом iPhone", role: .destructive) { disconnectPresented = true }
                        .font(.subheadline).disabled(working)
                }
            }
            CourierCard(preferences.configuration == nil ? "Подключить бота" : "Изменить подключение") {
                SecureField(preferences.configuration == nil ? "Токен из BotFather" : "Новый токен или оставь поле пустым", text: $tokenInput)
                    .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(Palette.field, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("telegram.token")
                Text("Токен хранится только в связке ключей этого iPhone.").font(.caption).foregroundStyle(Palette.muted)
                Text("Сначала добавь бота в курьерский чат, затем нажми «Найти чаты».")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                Button("Проверить бота и найти чаты") { discover() }
                    .buttonStyle(CourierButtonStyle()).disabled(working || effectiveToken == nil)
                    .accessibilityIdentifier("telegram.discover")
                if let verifiedBot { Label(verifiedBot, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(Palette.success) }
                if !chats.isEmpty {
                    Menu {
                        ForEach(chats, id: \.id) { chat in
                            Button(chat.title.isEmpty ? String(chat.id) : chat.title) {
                                destinationInput = String(chat.id)
                                threadInput = ""
                            }
                        }
                    } label: { Label("Выбрать найденный чат (\(chats.count))", systemImage: "bubble.left.and.bubble.right") }
                        .buttonStyle(CourierButtonStyle())
                }
                TextField("Ссылка на сообщение, @чат или ID", text: $destinationInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(Palette.field, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("telegram.destination")
                TextField("ID темы · необязательно", text: $threadInput)
                    .keyboardType(.numberPad).padding(12).background(Palette.field, in: RoundedRectangle(cornerRadius: 10))
                Text("Если чат не найден, вставь ссылку на сообщение или укажи его ID. Боту нужны права отправки сообщений.")
                    .font(.caption).foregroundStyle(Palette.muted)
                Button("Подключить") { connect() }
                    .buttonStyle(CourierButtonStyle(primary: true))
                    .disabled(working || effectiveToken == nil || destinationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("telegram.connect")
            }
            .disabled(working)
            CourierCard("Какие заказы присылать") {
                Toggle("Новый заказ", isOn: $preferences.created)
                Toggle("Заказ готов", isOn: $preferences.ready)
                Toggle("Только экспрессы", isOn: $preferences.onlyExpress)
                if !preferences.created && !preferences.ready { Text("Выбери хотя бы один тип уведомлений.").font(.caption).foregroundStyle(Palette.muted) }
            }
            if working { HStack { ProgressView(); Text("Проверяем…").font(.subheadline).foregroundStyle(Palette.muted) } }
            if let failure { CourierErrorCard(message: failure) }
            if let storageError = preferences.storageError { CourierErrorCard(message: storageError) }
            if let status { Text(status).font(.subheadline).foregroundStyle(Palette.muted) }
            if deliveryStatus != nil || lastSentAt != nil {
                CourierCard("Проверка заказов") {
                    if let deliveryStatus { Text(deliveryStatus).font(.subheadline).foregroundStyle(Palette.muted) }
                    if let lastSentAt { Text("Последняя отправка: \(lastSentAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(Palette.muted) }
                }
            }
        }
        .accessibilityIdentifier("telegram.settings")
        .confirmationDialog("Отключить бота на этом iPhone?", isPresented: $disconnectPresented, titleVisibility: .visible) {
            Button("Отключить", role: .destructive) { preferences.clear(); tokenInput = ""; verifiedBot = nil; chats = []; status = "Уведомления отключены на этом iPhone." }
        }
        .onChange(of: tokenInput) { _, _ in
            if clearingSavedToken { clearingSavedToken = false; return }
            verifiedBot = nil; chats = []; failure = nil; status = nil
        }
        .onChange(of: model.identity) { _, _ in cancelWork() }
        .onDisappear { cancelWork(); tokenInput = "" }
    }

    private var effectiveToken: String? {
        let value = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? preferences.token : value
    }

    private func discover() {
        guard let token = effectiveToken else { return }
        run {
            let api = TelegramBotAPI(token: token)
            let bot = try await api.getMe()
            try Task.checkCancellation()
            verifiedBot = "Бот проверен: @\(bot.username)"
            do {
                let found = try await api.discoverChats()
                try Task.checkCancellation()
                chats = found
                status = found.isEmpty ? "Чаты пока не найдены. После добавления бота отправь сообщение в чат и повтори поиск или введи адрес вручную." : "Выбери чат из списка или введи адрес вручную."
            } catch is CancellationError { throw CancellationError() }
            catch {
                chats = []
                failure = safeError(error)
                status = "Бот проверен. Поиск чатов недоступен; можно подключить чат вручную. Другой запуск этого бота или webhook может мешать поиску."
            }
        }
    }

    private func connect() {
        guard let token = effectiveToken else { return }
        run {
            let destination = try TelegramChatDestination.parse(input: destinationInput, threadInput: threadInput)
            let api = TelegramBotAPI(token: token)
            let bot = try await api.getMe()
            try Task.checkCancellation()
            let chat = try await api.getChat(destination)
            try Task.checkCancellation()
            try preferences.save(token: token, bot: bot, chat: chat, threadID: destination.threadID)
            if !tokenInput.isEmpty { clearingSavedToken = true; tokenInput = "" }
            verifiedBot = "Бот проверен: @\(bot.username)"
            status = "Подключено. Уведомления включены на этом iPhone."
        }
    }

    private func sendTest() {
        guard !model.demo, model.session != nil, let configuration = preferences.configuration,
              let token = preferences.token else { return }
        let identity = model.identity
        let fingerprint = model.api.sessionFingerprint
        let revision = preferences.revision
        run {
            guard try await model.api.activeShift() else {
                throw CourierError(message: "Для проверки отправки нужна активная смена ВВ.")
            }
            try Task.checkCancellation()
            guard !model.demo, model.session != nil, model.identity == identity,
                  model.api.sessionFingerprint == fingerprint, preferences.revision == revision,
                  preferences.configuration == configuration, preferences.token == token else {
                throw CourierError(message: "Вход или настройки изменились. Повтори проверку.")
            }
            try await TelegramBotAPI(token: token).sendMessage(to: configuration.chat,
                text: "Проверка уведомлений ВВ Курьер с iPhone. Это тестовое сообщение, нового заказа нет.")
            try Task.checkCancellation()
            status = "Тестовое сообщение отправлено в \(configuration.chatTitle.isEmpty ? configuration.chat.chatID : configuration.chatTitle)."
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        let id = UUID()
        operationID = id; working = true; failure = nil; status = nil
        work = Task { @MainActor in
            defer { if operationID == id { working = false; work = nil } }
            do { try await operation() }
            catch is CancellationError { }
            catch { if operationID == id { failure = safeError(error) } }
        }
    }

    private func cancelWork() {
        work?.cancel(); work = nil; operationID = UUID(); working = false
    }

    private func safeError(_ error: Error) -> String {
        var message = error.localizedDescription
        for token in [effectiveToken, preferences.token].compactMap({ $0 }) where !token.isEmpty {
            message = message.replacingOccurrences(of: token, with: "[токен скрыт]")
            if let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                message = message.replacingOccurrences(of: encoded, with: "[токен скрыт]")
            }
            if let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                message = message.replacingOccurrences(of: encoded, with: "[токен скрыт]")
            }
        }
        return message
    }
}
