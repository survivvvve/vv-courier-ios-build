import Foundation
import CoreFoundation

/// Deliberately excludes JavaScript messages, stacks, URLs, account data and
/// request payloads. Every text field is an enum or a narrowly validated value.
struct OriginalWebDiagnosticEvent: Codable, Equatable {
    enum Kind: String, Codable { case diagnostic }
    enum Category: String, Codable, CaseIterable {
        case typeUndefinedProperty = "type_undefined_property"
        case typeNullProperty = "type_null_property"
        case typeNotFunctionMap = "type_not_function_map"
        case typeNotFunctionForEach = "type_not_function_forEach"
        case typeNotFunctionConcat = "type_not_function_concat"
        case typeNotFunctionFilter = "type_not_function_filter"
        case domInsertBefore = "dom_insert_before"
        case domRemoveChild = "dom_remove_child"
        case domNotFound = "dom_not_found"
        case rangeInvalidTime = "range_invalid_time"
        case error, typeError = "type_error", rangeError = "range_error"
        case referenceError = "reference_error", syntaxError = "syntax_error"
        case domError = "dom_error", promiseRejection = "promise_rejection"
        case reactErrorScreen = "react_error_screen"
        case shiftChecksLoading = "shift_checks_loading", shiftChecksFailed = "shift_checks_failed"
    }
    enum Property: String, Codable, CaseIterable {
        case length, map, forEach, concat, filter, parcels, orders, suborders
        case filterParams, renderData, shopsData, coordinates, latitude, longitude
        case checking, route, checkingOption, parcelStatus = "parcel_status"
        case idParcel = "id_parcel", current, props, state, children
        case taskStatuses = "task_statuses", newStatuses = "new_statuses", payWay = "pay_way"
        case propertiesV2 = "properties_v2"
    }
    enum Path: String, Codable, CaseIterable {
        case start = "/start", auth = "/start/auth", authCode = "/start/auth/code"
        case my = "/main/my-tab", done = "/main/done-tab", prepare = "/main/prepare-tab"
        case queue = "/main/queue-tab", profile = "/main/profile-tab"
        case cluster = "/main/queue-tab/cluster/:id"
        case order = "/order", suborders = "/sub-orders", income = "/income"
        case incomeDetails = "/income-details", scan = "/scan", scanner = "/scanner"
        case packages = "/packages", checkPackages = "/check-packages", photoControl = "/photo-control"
        case other = "/<other>"
    }
    struct Frame: Codable, Equatable {
        let file: String
        let line: Int
        let column: Int
    }

    let kind: Kind
    let category: Category
    let fatal: Bool
    let path: Path
    let property: Property?
    let frames: [Frame]
    let version: String?
    let httpStatus: Int?
    let recordedAt: Date
}

/// Local-only bounded diagnostics. The WK controller validates origin and
/// documentID before calling record; this layer independently validates fields.
/// The controller owns calls on its main actor; no network or account access.
final class OriginalWebDiagnostics {
    static let shared = OriginalWebDiagnostics()
    static let capacity = 20
    static let maximumStoredBytes = 32_768
    private static let storageKey = "original.web.diagnostics.v1"
    private let defaults: UserDefaults
    private(set) var events: [OriginalWebDiagnosticEvent] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    @discardableResult
    func record(_ body: [String: Any], at date: Date = Date()) -> OriginalWebDiagnosticEvent? {
        guard let event = Self.validated(body, at: date) else { return nil }
        events.append(event)
        events = Array(events.suffix(Self.capacity))
        persist()
        return event
    }

    func clear() {
        events.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    var reportText: String {
        var lines = ["ВВ Курьер · диагностика сайта", "Событий: \(events.count)/\(Self.capacity)"]
        guard !events.isEmpty else { return (lines + ["Ошибок ещё не записано."]).joined(separator: "\n") }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for (index, event) in events.enumerated() {
            lines.append("\(index + 1). \(formatter.string(from: event.recordedAt)) \(event.fatal ? "fatal" : "error") \(event.category.rawValue)")
            var detail = event.path.rawValue
            if let version = event.version { detail += " · v\(version)" }
            if let property = event.property { detail += " · property=\(property.rawValue)" }
            if let status = event.httpStatus { detail += status == 0 ? " · network" : " · HTTP \(status)" }
            lines.append(detail)
            lines += event.frames.map { "\($0.file):\($0.line):\($0.column)" }
        }
        return lines.joined(separator: "\n")
    }

    private static func validated(_ body: [String: Any], at date: Date) -> OriginalWebDiagnosticEvent? {
        guard body["kind"] as? String == OriginalWebDiagnosticEvent.Kind.diagnostic.rawValue,
              let rawCategory = body["category"] as? String,
              let category = OriginalWebDiagnosticEvent.Category(rawValue: rawCategory),
              let rawFatal = body["fatal"] as? NSNumber,
              CFGetTypeID(rawFatal) == CFBooleanGetTypeID() else { return nil }
        let path = (body["path"] as? String).flatMap(OriginalWebDiagnosticEvent.Path.init(rawValue:)) ?? .other
        let property = (body["property"] as? String).flatMap(OriginalWebDiagnosticEvent.Property.init(rawValue:))
        let version = (body["version"] as? String).flatMap { matches($0, "^[0-9]{1,4}(\\.[0-9]{1,4}){1,3}$") ? $0 : nil }
        var httpStatus: Int?
        if let raw = body["httpStatus"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite,
                  value.doubleValue.rounded(.towardZero) == value.doubleValue,
                  value.doubleValue == 0 || (100...599).contains(value.doubleValue) else { return nil }
            httpStatus = Int(value.doubleValue)
        }
        let candidates = body["frames"] as? [Any] ?? []
        let frames = candidates.prefix(6).compactMap { raw -> OriginalWebDiagnosticEvent.Frame? in
            guard let value = raw as? [String: Any], let file = value["file"] as? String,
                  matches(file, "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,119}\\.(?:m?js)$"),
                  file.range(of: "authorization|cookie|bearer|token|secret|password|phone|address", options: [.regularExpression, .caseInsensitive]) == nil,
                  file.range(of: "[0-9]{6}", options: .regularExpression) == nil,
                  let line = positiveInteger(value["line"]), let column = positiveInteger(value["column"]) else { return nil }
            return OriginalWebDiagnosticEvent.Frame(file: file, line: line, column: column)
        }
        guard date.timeIntervalSince1970.isFinite, date >= .distantPast, date <= .distantFuture else { return nil }
        return OriginalWebDiagnosticEvent(kind: .diagnostic, category: category, fatal: rawFatal.boolValue,
            path: path, property: property, frames: frames, version: version, httpStatus: httpStatus, recordedAt: date)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        // Bound before regex work; a hostile error must not grow this store.
        text.utf8.count <= 128 && text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func positiveInteger(_ raw: Any?) -> Int? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number.rounded(.towardZero) == number, (1...10_000_000).contains(number) else { return nil }
        return Int(number)
    }

    private func restore() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        guard data.count <= Self.maximumStoredBytes,
              let container = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = container["events"] as? [Any] else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        events = rows.suffix(Self.capacity).compactMap { row in
            guard let value = row as? [String: Any],
                  let timestamp = value["recordedAt"] as? NSNumber,
                  CFGetTypeID(timestamp) != CFBooleanGetTypeID(), timestamp.doubleValue.isFinite else { return nil }
            // Codable Date defaults to seconds since 2001. No JS timestamp is
            // accepted by record; this value is native-created storage only.
            let date = Date(timeIntervalSinceReferenceDate: timestamp.doubleValue)
            return Self.validated(value, at: date)
        }
        // Canonical rewrite removes unknown keys even from tampered storage.
        persist()
    }

    private func persist() {
        struct Snapshot: Encodable { let events: [OriginalWebDiagnosticEvent] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        while let data = try? encoder.encode(Snapshot(events: events)) {
            if data.count <= Self.maximumStoredBytes {
                defaults.set(data, forKey: Self.storageKey)
                return
            }
            guard !events.isEmpty else { break }
            events.removeFirst()
        }
        defaults.removeObject(forKey: Self.storageKey)
    }
}
