import Foundation

enum Demo {
    static func orders(_ feed: Feed) -> [Parcel] {
        let streets = ["Тестовая улица, 5", "Примерный проспект, 12", "Учебный переулок, 7", "Демонстрационная улица, 3"]
        let weights = [1.2, 2.8, 5.9, 7.4]
        let deadlines = [45, 22, 9, -3]
        return (0..<4).map { index in
            var raw: [String: Any] = [
                "id_parcel": "demo-\(feed.rawValue)-\(index)", "id_general_view": "100\(index)",
                "shopno": index.isMultiple(of: 2) ? 101 : 202,
                "user_address": feed == .assembly ? "Квартира: 12; Домофон: 12; Подъезд: 2; Этаж: 4;" : streets[index],
                "corr_addr": "Санкт-Петербург, посёлок Парголово, " + streets[index],
                "latitude": [60.074, 60.077, 60.071, 60.08][index], "longitude": [30.33, 30.336, 30.343, 30.327][index],
                "colour_parcel": feed == .assembly ? (index < 2 ? "violet" : "red") : "green",
                "listNumber": feed == .assembly ? index % 2 + 1 : index + 1,
                "delivery_address": ["flat": "12", "entrance": "2", "floor": "4"],
                "weight": weights[index], "reward": 140 + index * 12,
                "pay_way": 0, "count_pack": 2,
                "orders": [["id_order": "demo-sub-\(index)", "id_general_view": "100\(index)", "packages": [["id_package": "demo-a-\(index)", "id_cell": "CO-1-1"], ["id_package": "demo-b-\(index)", "id_cell": "CZ-1-2"]]]],
                "fast_delivery": index == 1 ? 1 : 0,
                "date_supply_until_rfc": ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(deadlines[index]) * 60)),
                "date_collect_start_rfc": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-420)),
                "comment": feed == .assembly ? "Демо покупателя: оставьте заказ у двери." : "Демо покупателя: позвоните перед доставкой.",
                "comment_client": 4313,
                "comment_courier_address": "Демо: вход со двора.",
                "properties": index == 2 ? [["pp_id": "761", "text": "Вода"]] : [["text": "Яйца"]],
                "parcel_status": feed == .mine ? "pickuped" : feed == .assembly ? "created" : "assembled"
            ]
            if feed == .available && index == 0 {
                raw["pay_way"] = 4; raw["pay_summ"] = 2500
                raw["comment"] = "Демо: оставить у двери. Нужна сдача с 5000 рублей."
            }
            if feed == .mine && index == 0 {
                raw["parcel_status"] = "on_the_way"; raw["pay_way"] = 3; raw["pay_summ"] = 2500
            }
            if feed == .assembly && index >= 2 { raw.removeValue(forKey: "date_collect_start_rfc") }
            if feed == .assembly && index == 1 {
                raw["user_address"] = ""
                raw["delivery_address"] = ["usable": true, "address": "Санкт-Петербург, " + streets[index], "flat": "12", "entrance": "2", "floor": "4", "doorphone": "12"]
            }
            return Parcel(raw)
        }
    }
}
