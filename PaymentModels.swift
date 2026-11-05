import Foundation

enum DeliveryPaymentMethod: String, CaseIterable, Identifiable {
    case cash, terminal, terminalQR
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cash: return "Клиент оплатил наличными"
        case .terminal: return "Клиент оплатил по терминалу"
        case .terminalQR: return "Клиент оплатил QR-кодом терминала"
        }
    }
    var payWay: Int { self == .cash ? 4 : 3 }
}

struct DeliveryPaymentConfirmation {
    let method: DeliveryPaymentMethod
    let amountDue: Decimal
    var cashReceived: Decimal? = nil
}

struct DeliveryCompletion {
    let parcelID: String
    let payWay: Int?
    var needsReceipt: Bool { payWay == 3 }
}

enum DeliveryPaymentRules {
    static func amount(_ value: Any?) -> Decimal? {
        let text = string(value).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: "\u{202f}", with: "").replacingOccurrences(of: ",", with: ".")
        guard text.range(of: #"^[0-9]{1,9}(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
    static func amountDue(_ parcel: [String: Any]) -> Decimal? {
        guard let payable = amount(parcel["pay_summ"]) else { return nil }
        return payable == 0 ? amount(parcel["pay_sum_cancelled"]) ?? payable : payable
    }
    static func decimalString(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    /// First-party checkOrderDone bypasses collection only for actual server
    /// paid CASH/TERMINAL orders or their zero remaining price (never hyperlink).
    static func collectionNotRequired(_ parcel: [String: Any]) -> Bool {
        guard let way = integer(parcel["pay_way"]) else { return false }
        if [0, 2, 5].contains(way) { return true }
        guard [3, 4].contains(way) else { return false }
        return ["1", "true"].contains(string(parcel["paid"]).lowercased()) || (amount(parcel["pay_summ"]) == 0 && amount(parcel["pay_sum_cancelled"]) == 0)
    }
    static func usesPaidCollectionBranch(_ parcel: [String: Any]) -> Bool {
        [3, 4].contains(integer(parcel["pay_way"]) ?? -1) && collectionNotRequired(parcel)
    }
    /// Archive/closure actual payment must come from VV, not from our legacy
    /// A6e request mapping (which sends pay_way4 for an already paid terminal).
    static func actualPaymentWay(_ parcel: [String: Any]) -> Int? {
        guard let way = integer(parcel["pay_way_fact"]), [0, 1, 2, 3, 4, 5, 9].contains(way) else { return nil }
        return way
    }
    static func assignedSberTerminal(_ status: [String: Any]) -> String? {
        let id = string(status["terminal_id"])
        guard [0, 2].contains(integer(status["res"]) ?? -1), !id.isEmpty, id != "0", (integer(status["shopno"]) ?? 0) > 0,
              !id.lowercased().contains("s") else { return nil }
        return id
    }
    static func methods(terminal: [String: Any]) -> [DeliveryPaymentMethod] {
        assignedSberTerminal(terminal) == nil ? [.cash] : [.terminal, .cash, .terminalQR]
    }
    static func completionBody(parcel: [String: Any], courierID: String, confirmation: DeliveryPaymentConfirmation?, terminal: [String: Any], flags: Set<Int>) throws -> [String: Any] {
        let id = string(parcel["id_parcel"])
        guard !id.isEmpty, !courierID.isEmpty, let amount = amountDue(parcel) else { throw CourierError(message: "ВВ не сообщил сумму к оплате. Обнови заказ.") }
        let original = Int(string(parcel["pay_way"]))
        var body: [String: Any] = ["id_courier": courierID, "id_parcel": id, "status": "delivered", "sum_pay": decimalString(amount)]
        guard original != 9 else { throw CourierError(message: "Проверка оплаты по ссылке пока не поддерживается. Завершение этого заказа недоступно; способ оплаты не изменён.") }
        if usesPaidCollectionBranch(parcel) {
            guard confirmation == nil, let original, let originalAmount = self.amount(parcel["pay_summ"]) else { throw CourierError(message: "ВВ уже подтвердил оплату или нулевую сумму. Обнови заказ, повторное получение оплаты не требуется.") }
            // Exact first-party A6e body, intentionally without new cash entry.
            body["pay_way"] = original == 3 ? 4 : original
            body["sum_pay"] = decimalString(originalAmount)
            return body
        }
        if let confirmation {
            guard [1, 3, 4].contains(original ?? -1), confirmation.amountDue == amount else { throw CourierError(message: "Сумма или способ оплаты изменились. Обнови заказ перед подтверждением.") }
            body["pay_way"] = confirmation.method.payWay
            if confirmation.method == .cash {
                guard let received = confirmation.cashReceived, received >= amount else { throw CourierError(message: "Полученная сумма не может быть меньше суммы заказа.") }
                // The VV cash balance records the order price, not the banknote
                // handed over before change. Same YLe calculation as web client.
                if flags.contains(100) { body["cash_received"] = NSDecimalNumber(decimal: amount * 100).int64Value }
            } else {
                guard let id = assignedSberTerminal(terminal) else { throw CourierError(message: "Нет назначенного терминала с ручным подтверждением оплаты. Обнови статус терминала.") }
                body["id_terminal"] = id
                if confirmation.method == .terminalQR { body["type_id"] = 2 }
            }
        } else {
            guard let original, [0, 2, 5].contains(original) else { throw CourierError(message: "Сначала выбери фактический способ оплаты покупателем.") }
            body["pay_way"] = original
        }
        return body
    }
}

struct ReceiptPhoto: Identifiable, Codable, Equatable {
    let id: String
    let url: String
    init?(_ raw: [String: Any]) {
        let id = string(raw["id_photo"]), url = string(raw["url_photo"])
        guard !id.isEmpty, let target = URL(string: url), target.scheme == "https" else { return nil }
        self.id = id; self.url = url
    }
}

struct ReceiptDraftPhoto: Identifiable, Codable {
    var id = UUID()
    let jpeg: Data
    var uploadedID: String?
}

enum ReceiptDraftStore {
    private static func target(courierID: String, parcelID: String) -> URL? {
        guard !courierID.isEmpty, !parcelID.isEmpty else { return nil }
        let safeCourier = courierID.filter { $0.isNumber || $0.isLetter || $0 == "-" }, safeParcel = parcelID.filter { $0.isNumber || $0.isLetter || $0 == "-" }
        guard safeCourier == courierID, safeParcel == parcelID else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ReceiptDrafts", isDirectory: true).appendingPathComponent(courierID, isDirectory: true).appendingPathComponent(parcelID + ".json")
    }
    static func load(courierID: String, parcelID: String) -> [ReceiptDraftPhoto] {
        guard let target = target(courierID: courierID, parcelID: parcelID), let data = try? Data(contentsOf: target) else { return [] }
        return (try? JSONDecoder().decode([ReceiptDraftPhoto].self, from: data)) ?? []
    }
    static func save(_ photos: [ReceiptDraftPhoto], courierID: String, parcelID: String) throws {
        guard let target = target(courierID: courierID, parcelID: parcelID) else { throw CourierError(message: "Не удалось сохранить черновик фото.") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(photos)
        try data.write(to: target, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
        #endif
    }
    static func clear(courierID: String, parcelID: String) {
        if let target = target(courierID: courierID, parcelID: parcelID) { try? FileManager.default.removeItem(at: target) }
    }
}
