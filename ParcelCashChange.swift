import Foundation

struct ParcelCashChange: Equatable {
    let tendered: Decimal
    let amountDue: Decimal
    var change: Decimal { tendered - amountDue }

    static func calculate(comments: [String], amountDue: Any?) -> ParcelCashChange? {
        guard let due = amount(amountDue), due > 0 else { return nil }
        guard !comments.contains(where: { $0.range(of: noChangePattern, options: .regularExpression) != nil }) else { return nil }
        let pattern = #"(?i)(?<![а-яё])сдач[ауи]?(?![а-яё])\s+(?:пожалуйста[,\s]+)?(?:с|со)\s+(?:купюры\s+)?[:]?\s*((?:[0-9]{1,3}(?:[ \u00a0\u202f][0-9]{3})+|[0-9]{1,9})(?:[.,][0-9]{1,2})?)\s*(тыс(?:яч(?:и|а)?)?\.?)?(?![0-9]|[.,][0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var found: Decimal?
        for comment in comments {
            for match in regex.matches(in: comment, range: NSRange(comment.startIndex..., in: comment)) {
                guard let range = Range(match.range(at: 1), in: comment), var value = amount(String(comment[range])) else { return nil }
                if match.range(at: 2).location != NSNotFound { value *= 1000 }
                // "С 5000 или 10000" is not a single promise of cash.
                if let whole = Range(match.range, in: comment) {
                    let tail = comment[whole.upperBound...].prefix { $0 != "\n" && $0 != "." && $0 != ";" }
                    if tail.range(of: #"(?i)(?<![а-яё])или(?![а-яё])"#, options: .regularExpression) != nil { return nil }
                }
                guard value >= due, found == nil || found == value else { return nil }
                found = value
            }
        }
        guard let tendered = found else { return nil }
        return ParcelCashChange(tendered: tendered, amountDue: due)
    }

    private static let noChangePattern = #"(?i)(?:без\s+сдачи|сдач[аиу]?\s+не\s+(?:нужн[аоы]?|надо)|не\s+(?:нужн[аоы]?|надо)\s+сдач[аиу]?)"#
    static func hasChangeRequest(_ comments: [String]) -> Bool {
        comments.contains {
            let positive = $0.replacingOccurrences(of: noChangePattern, with: "", options: .regularExpression)
            return positive.range(of: #"(?i)(?<![а-яё])сдач[а-яё]*(?![а-яё])"#, options: .regularExpression) != nil
        }
    }

    private static func amount(_ value: Any?) -> Decimal? {
        guard let value, !(value is NSNull) else { return nil }
        let text: String
        if let number = value as? NSNumber { text = number.stringValue }
        else if let string = value as? String { text = string }
        else { return nil }
        let normalized = text.replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: "\u{202f}", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[0-9]{1,9}(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }
}

extension Parcel {
    var effectivePaymentWay: Int? {
        let value = status == "delivered" ? firstAddressText(raw["pay_way_fact"], raw["pay_way"]) : addressText(raw["pay_way"])
        return Int(value)
    }
    var isCashPayment: Bool { effectivePaymentWay == 4 }
    var cashWithoutChange: Bool { isCashPayment && !ParcelCashChange.hasChangeRequest(buyerComments) }
    var cashChange: ParcelCashChange? {
        // An old cash comment must not create change for an online/terminal order.
        guard isCashPayment else { return nil }
        return ParcelCashChange.calculate(comments: buyerComments, amountDue: raw["pay_summ"])
    }
}
