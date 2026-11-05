import Foundation

/// VV's legacy address is split between corr_addr (street/house) and
/// user_address (often only flat, entrance, intercom and floor). Empty modern
/// fields must not hide the populated legacy part.
struct ParcelAddress {
    let street: String
    let flat: String
    let entrance: String
    let floor: String
    let doorphone: String
    var detailsLine: String {
        [("кв.", flat), ("п", entrance), ("эт.", floor)].compactMap { prefix, value in value.isEmpty ? nil : prefix + " " + value }.joined(separator: " · ")
    }
    var formatted: String { [street, detailsLine].filter { !$0.isEmpty }.joined(separator: " · ") }

    init(_ raw: [String: Any]) {
        let detail = raw["delivery_address"] as? [String: Any] ?? [:]
        let map = raw["map_info"] as? [String: Any] ?? [:]
        let modern = addressText(detail["address"])
        let corr = firstAddressText(raw["corr_addr"], map["corr_addr"])
        let user = addressText(raw["user_address"])
        let sources = [modern, corr, user]
        flat = firstAddressText(detail["flat"], detail["apartment"], raw["flat"], raw["apartment"], Self.label("(?:квартира|кв\\.?)", in: sources))
        entrance = firstAddressText(detail["entrance"], detail["entry"], raw["entrance"], Self.label("(?:подъезд|парадная|п\\.?)", in: sources))
        floor = firstAddressText(detail["floor"], raw["floor"], Self.label("(?:этаж|эт\\.?)", in: sources))
        doorphone = firstAddressText(detail["doorphone"], detail["intercom"], raw["doorphone"], Self.label("(?:домофон)", in: sources))
        let legacyParts = [Self.withoutDetails(corr), Self.withoutDetails(user)].filter { !$0.isEmpty }
        var unique = [String]()
        for value in legacyParts where !unique.contains(where: { Self.withoutLeadingLocality($0).caseInsensitiveCompare(Self.withoutLeadingLocality(value)) == .orderedSame }) { unique.append(value) }
        let legacy = unique.joined(separator: ", ")
        let structured = Self.structuredStreet(detail, raw: raw)
        let usable = detail["usable"].map { truth($0) } ?? true
        let full = firstAddressText(usable ? Self.withoutDetails(modern) : nil, legacy, Self.withoutDetails(modern), raw["address"], structured)
        let localities = [detail["city"], detail["settlement"], detail["region"], detail["district"], detail["federal_district"], raw["city"], raw["settlement"], raw["region"], raw["district"], raw["federal_district"]].compactMap { value -> String? in let text = addressText(value); return text.isEmpty ? nil : text }
        street = Self.withoutLeadingLocality(full, known: localities)
    }

    private static func label(_ expression: String, in texts: [String]) -> String {
        let pattern = "(?i)(?:^|[;,\\n])\\s*" + expression + "\\s*[:№]\\s*([^;,\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        for text in texts {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private static func withoutDetails(_ text: String) -> String {
        let pattern = "(?i)(?:^|[;,\\n])\\s*(?:квартира|кв\\.?|домофон|подъезд|парадная|этаж|эт\\.?)\\s*[:№]"
        let range = text.range(of: pattern, options: .regularExpression)
        return String(range.map { text[..<$0.lowerBound] } ?? text[...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
    }

    static func withoutLeadingLocality(_ full: String, known: [String] = []) -> String {
        var parts = full.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let exact = Set((known + ["Россия", "Российская Федерация", "РФ", "Санкт-Петербург", "СПб", "Москва", "Парголово"]).map { $0.lowercased() })
        let streetPattern = #"(?:^|\s)(?:улица|ул\.?|проспект|пр-т|проезд|пр-д|переулок|пер\.?|шоссе|набережная|наб\.?|бульвар|бул\.?|площадь|пл\.?|аллея|дорога|линия|тупик|тракт)(?:\s|$)"#
        let localityPattern = #"^(?:г\.\s*|г\s+|город\s+|пос[её]лок\s+|пос\.\s*|п\.\s*|пгт\.?\s+|деревня\s+|дер\.\s*|с\.\s*|село\s+)"#
        let administrationPatterns = [
            #"(?:^|\s)федеральный\s+округ$"#,
            #"\s+(?:муниципальный|городской|административный|территориальный)\s+(?:округ|район)$"#,
            #"(?:^|\s)(?:фо|фед\.\s*округ)$"#,
            #"(?:^|\s)(?:область|обл\.|край|автономный\s+округ|ао|район|р-н)$"#,
            #"^(?:республика|респ\.)\s+|\s+(?:республика|респ\.)$"#,
            #"^(?:муниципальн(?:ый|ое)|городской|административный|внутригородск(?:ой|ое))\s+(?:округ|район|образование)"#,
            #"^внутригородское\s+муниципальное\s+образование"#,
            #"^[0-9]{6}$"#
        ]
        while let first = parts.first {
            let lower = first.lowercased()
            if first.isEmpty || exact.contains(lower) { parts.removeFirst(); continue }
            // Stop as soon as a street component begins. Administrative words
            // occurring inside a street's proper name must remain untouched.
            if lower.range(of: streetPattern, options: .regularExpression) != nil { break }
            let named = lower.replacingOccurrences(of: #"^(?:г\.?|город)\s+"#, with: "", options: .regularExpression)
            let isLocality = lower.range(of: localityPattern, options: .regularExpression) != nil
            let isAdministration = administrationPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
            guard exact.contains(named) || isLocality || isAdministration else { break }
            parts.removeFirst()
        }
        return parts.joined(separator: ", ")
    }

    private static func structuredStreet(_ details: [String: Any], raw: [String: Any]) -> String {
        let street = firstAddressText(details["street"], details["street_name"], raw["street"], raw["street_name"])
        guard !street.isEmpty else { return "" }
        let house = firstAddressText(details["house"], details["house_number"], raw["house"])
        let corpus = firstAddressText(details["corpus"], details["block"], raw["corpus"])
        let structure = firstAddressText(details["structure"], details["building_number"], raw["structure"])
        var value = street
        if !house.isEmpty && !street.hasSuffix(" " + house) && !street.hasSuffix(", " + house) { value += ", " + house }
        if !corpus.isEmpty && !value.hasSuffix("к" + corpus) { value += "к" + corpus }
        if !structure.isEmpty { value += ", стр. " + structure }
        return value
    }
}

func addressText(_ raw: Any?) -> String {
    if let value = raw as? String { return value.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    if let value = raw as? NSNumber { return value.stringValue }
    return ""
}

func firstAddressText(_ values: Any?...) -> String { values.lazy.map(addressText).first(where: { !$0.isEmpty }) ?? "" }
