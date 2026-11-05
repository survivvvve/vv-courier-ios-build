import Foundation

struct ParcelPackageLocation: Identifiable {
    let id: String
    let count: Int
}

struct ParcelSuborder: Identifiable {
    let id: String
    let label: String
    let cancelled: Bool
    let locations: [ParcelPackageLocation]
    let packageCount: Int
    static func parse(_ parcel: Parcel) -> [ParcelSuborder] {
        let rows = parcel.raw["orders"] as? [[String: Any]] ?? []
        return rows.enumerated().map { index, order in
            let packages = order["packages"] as? [[String: Any]] ?? []
            var counts: [String: Int] = [:], cells: [String] = [], seen = Set<String>()
            var count = 0
            for package in packages {
                let packageID = string(package["id_package"])
                if !packageID.isEmpty && !seen.insert(packageID).inserted { continue }
                count += 1
                let cell = string(package["id_cell"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if counts[cell] == nil { cells.append(cell) }
                counts[cell, default: 0] += 1
            }
            let id = string(order["id_order"])
            return ParcelSuborder(id: id.isEmpty ? "row-\(index)" : id,
                                  label: string(order["id_general_view"] ?? order["id_order"]),
                                  cancelled: truth(order["canceled"]) || truth(order["cancel_by_customer"]),
                                  locations: cells.map { ParcelPackageLocation(id: $0, count: counts[$0]!) }, packageCount: count)
        }
    }
}

import SwiftUI

struct ParcelPackagesCard: View {
    let parcel: Parcel
    private var orders: [ParcelSuborder] { ParcelSuborder.parse(parcel) }
    var body: some View {
        if !orders.isEmpty {
            CourierCard("Подзаказы и ячейки") {
                ForEach(orders) { order in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(order.label.isEmpty ? "Подзаказ" : order.label).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(order.cancelled ? "Отменён" : "Мест: \(order.packageCount)")
                                .font(.caption).foregroundStyle(order.cancelled ? Palette.danger : Palette.muted)
                        }
                        if order.locations.isEmpty { Text("Ячейки пока не назначены").font(.caption).foregroundStyle(Palette.muted) }
                        ForEach(order.locations) { location in
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox").foregroundStyle(Palette.muted)
                                Text(location.id.isEmpty ? "Ячейка не указана" : location.id).monospaced()
                                Spacer()
                                Text("Мест: \(location.count)").foregroundStyle(Palette.muted)
                            }.font(.caption)
                        }
                    }.accessibilityIdentifier("order.packages.\(order.id)")
                    if order.id != orders.last?.id { Divider() }
                }
            }
        }
    }
}
