import Foundation

enum ParcelMapPayload {
    static func enrich(_ rows: [[String: Any]], map: [String: Any]) -> [[String: Any]] {
        var pins: [String: [String: Any]] = [:]
        for pin in map["parcels"] as? [[String: Any]] ?? [] {
            let id = string(pin["id_parcel"])
            if !id.isEmpty { pins[id] = pin }
        }
        return rows.map { original in
            guard let pin = pins[string(original["id_parcel"])] else { return original }
            var row = original
            row["map_info"] = pin
            if string(row["corr_addr"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !string(pin["corr_addr"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row["corr_addr"] = pin["corr_addr"]
            }
            return row
        }
    }

    static func appendShops(_ rows: [[String: Any]], to shops: inout [[String: Any]]) {
        func identity(_ row: [String: Any]) -> String {
            [firstAddressText(row["shopno"], row["shop_number"], row["ShopNO"]),
             firstAddressText(row["latitude"], row["latitude_tt"], row["shop_lat"], row["lat"]),
             firstAddressText(row["longitude"], row["longitude_tt"], row["shop_lon"], row["lon"])].joined(separator: ":")
        }
        var seen = Set(shops.map(identity))
        for row in rows where seen.insert(identity(row)).inserted { shops.append(row) }
    }
}
