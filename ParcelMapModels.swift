import Foundation

struct ParcelCoordinate: Codable, Hashable {
    let latitude: Double
    let longitude: Double
    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 else { return nil }
        self.latitude = latitude; self.longitude = longitude
    }
    init?(_ raw: [String: Any]) {
        let pairs = [("latitude", "longitude"), ("lat", "lon"), ("lat", "lng"), ("Latitude", "Longitude"), ("latitude_tt", "longitude_tt"), ("shop_lat", "shop_lon")]
        for (latitudeKey, longitudeKey) in pairs {
            guard let latitude = Self.scalar(raw[latitudeKey]), let longitude = Self.scalar(raw[longitudeKey]), let point = Self(latitude: latitude, longitude: longitude) else { continue }
            self = point; return
        }
        return nil
    }
    private static func scalar(_ raw: Any?) -> Double? {
        let value = addressText(raw).replacingOccurrences(of: ",", with: ".")
        guard !value.isEmpty, let number = Double(value), number.isFinite else { return nil }
        return number
    }
}

extension Shop {
    var mapCoordinate: ParcelCoordinate? {
        guard let latitude, let longitude else { return nil }
        return ParcelCoordinate(latitude: latitude, longitude: longitude)
    }
}

extension Parcel {
    var mapCoordinate: ParcelCoordinate? {
        let map = raw["map_info"] as? [String: Any] ?? [:]
        let details = raw["delivery_address"] as? [String: Any] ?? [:]
        let location = raw["coordinates"] as? [String: Any] ?? [:]
        return ParcelCoordinate(map) ?? ParcelCoordinate(raw) ?? ParcelCoordinate(details) ?? ParcelCoordinate(location)
    }
    var mapListNumber: Int? {
        let map = raw["map_info"] as? [String: Any] ?? [:]
        let value = firstAddressText(map["listNumber"], raw["listNumber"])
        guard let number = Int(value), number > 0 else { return nil }
        return number
    }
    func mapColorName(feed: Feed, shopColor: String? = nil) -> String {
        let map = raw["map_info"] as? [String: Any] ?? [:]
        let provided = firstAddressText(map["color"], map["colour_parcel"], raw["color"], raw["colour_parcel"])
        if !provided.isEmpty { return provided }
        if feed == .assembly { return assemblyStarted == nil ? "red" : "violet" }
        return firstAddressText(shopColor, "green")
    }
}

/// Exact named-color conversion used by the official courier web map (bq).
enum ParcelMapColors {
    static func hex(_ name: String) -> String {
        if name.hasPrefix("#") {
            let digits = String(name.dropFirst())
            if digits.count == 6, UInt64(digits, radix: 16) != nil { return "#" + digits.uppercased() }
            if digits.count == 3, UInt64(digits, radix: 16) != nil { return "#" + digits.map { String(repeating: String($0), count: 2) }.joined().uppercased() }
        }
        return ["blue": "#187BCC", "red": "#E54F4F", "darkOrange": "#D36B1B", "night": "#2A3D4C", "darkBlue": "#0F4779", "pink": "#EA87BA", "grey": "#C2C2C2", "brown": "#AA7E57", "darkGreen": "#223C2C", "violet": "#A445F2", "black": "#1A1A1A", "yellow": "#FFD21D", "green": "#179C49", "orange": "#FA9925", "lightBlue": "#71BAF6", "olive": "#97A102"][name] ?? "#187BCC"
    }
}

struct ParcelMapEntry: Identifiable {
    let parcel: Parcel
    let number: Int
    let colorName: String
    var id: String { parcel.id }
    var coordinate: ParcelCoordinate? { parcel.mapCoordinate }
    static func entries(_ parcels: [Parcel], feed: Feed, shopColors: [Int: String] = [:]) -> [ParcelMapEntry] {
        var categoryNumbers: [String: Int] = [:]
        return parcels.enumerated().map { index, parcel in
            let color = parcel.mapColorName(feed: feed, shopColor: parcel.shopID.flatMap { shopColors[$0] })
            categoryNumbers[color, default: 0] += 1
            let fallback = feed == .assembly ? categoryNumbers[color]! : index + 1
            return ParcelMapEntry(parcel: parcel, number: parcel.mapListNumber ?? fallback, colorName: color)
        }
    }
}
