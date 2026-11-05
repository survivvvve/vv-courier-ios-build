import SwiftUI

struct PartnerPickupLink: View {
    let parcel: Parcel
    let refresh: () async -> Void
    var body: some View {
        NavigationLink {
            PartnerPickupView(parcel: parcel, onUpdated: refresh)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "bag").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Выдача партнёра · " + parcel.label).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                    Text("Подзаказы и подтверждение получения").font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
            }.padding(.vertical, 5)
        }.buttonStyle(.plain).accessibilityIdentifier("partner.pickup." + parcel.id)
    }
}

struct PartnerPickupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let parcel: Parcel
    let onUpdated: () async -> Void
    @State private var snapshot: PartnerPickupSnapshot?
    @State private var loading = false
    @State private var working = false
    @State private var operationTask: Task<Void, Never>?
    @State private var failure: String?
    @State private var status: String?
    @State private var arrivals: [String: PartnerArrivalReceipt] = [:]
    @State private var confirmation: PartnerPickupSuborder?
    var body: some View {
        CourierPage("Выдача партнёра", subtitle: "Заказ " + parcel.fullNumber, artwork: 2) {
            if model.demo { DemoBanner() }
            Text("Проверь каждый подзаказ в точке выдачи. Эта отметка не заменяет стикеры пакетов и оплату при доставке.").font(.subheadline).foregroundStyle(Palette.muted)
            if loading { ProgressView("Загружаю точки выдачи…") }
            if let failure { CourierErrorCard(message: failure) { Task { await load() } } }
            if let status { Text(status).font(.subheadline).foregroundStyle(Palette.accent) }
            if let snapshot {
                ForEach(snapshot.groups) { group in
                    CourierCard(group.title) {
                        if !group.address.isEmpty { Text(group.address).font(.subheadline).textSelection(.enabled) }
                        ForEach(group.suborders) { order in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: order.checked ? "checkmark.circle.fill" : "bag").foregroundStyle(order.checked ? Palette.success : Palette.accent)
                                    Text("Подзаказ " + order.label).font(.subheadline.weight(.semibold))
                                    Spacer()
                                }
                                HStack {
                                    Text(order.packageCount.map { "Пакетов: \($0)" } ?? "Пакеты не указаны")
                                    if let weight = order.weight { Text(String(format: "· %.3f кг", weight)) }
                                }.font(.caption).foregroundStyle(Palette.muted)
                                if snapshot.parcel.status == "pickuped" {
                                    if !order.checked && snapshot.requiresArrival && arrivals[order.id] == nil {
                                        Button("Прибыл за заказом") { arrive(order) }.buttonStyle(CourierButtonStyle()).disabled(working || loading || model.busy).accessibilityIdentifier("partner.arrive." + order.id)
                                    } else {
                                        Button(order.checked ? "Снять отметку получения" : "Подзаказ получен") { confirmation = order }
                                            .buttonStyle(CourierButtonStyle(primary: !order.checked)).disabled(working || loading || model.busy).accessibilityIdentifier("partner.confirm." + order.id)
                                    }
                                } else { Text(order.checked ? "Получение подтверждено ВВ" : "Получение не подтверждено").font(.caption).foregroundStyle(Palette.muted) }
                            }.padding(.vertical, 7).accessibilityElement(children: .contain).accessibilityIdentifier("partner.suborder." + order.id)
                        }
                    }
                }
                if snapshot.allChecked { Label("Все подзаказы получены", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.medium)).foregroundStyle(Palette.success).accessibilityIdentifier("partner.all-confirmed") }
                if snapshot.requiresDistance { Text("Для отметки партнёрской точки ВВ требует реальное нахождение в пределах 500 м.").font(.caption).foregroundStyle(Palette.muted) }
            }
            Button("Обновить выдачу") { Task { await load() } }.buttonStyle(CourierButtonStyle()).disabled(working || loading || model.busy)
            Button("Готово") { dismiss() }.buttonStyle(CourierButtonStyle(primary: snapshot?.allChecked == true)).disabled(working)
        }.task { await load() }.interactiveDismissDisabled(working).accessibilityIdentifier("partner.screen")
            .onDisappear { operationTask?.cancel() }
            .onChange(of: model.identity) { _, _ in operationTask?.cancel() }
            .confirmationDialog(confirmation?.checked == true ? "Снять отметку получения подзаказа?" : "Ты получил этот подзаказ и сверил пакеты?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                if let order = confirmation {
                    Button(order.checked ? "Снять отметку" : "Подтвердить получение") { confirmation = nil; confirm(order) }
                }
            }
    }
    @MainActor private func read() async throws -> PartnerPickupSnapshot {
        if model.demo {
            let raw: [String: Any] = ["parcel_addresses": [["partner_name": "Демонстрационный партнёр", "id_partner": 1, "user_address": "Учебная улица, 1", "suborders": [["id_order": "10001", "check": snapshot?.allChecked == true ? 1 : 0, "collected_pkgs": 2, "order_weight": 1.2]]]]]
            return try PartnerPickupSnapshot.parse(raw, parcel: parcel)
        }
        return try await model.api.partnerPickupSnapshot(parcelID: parcel.id)
    }
    @MainActor private func load() async {
        guard !working, !loading else { return }; loading = true; failure = nil
        defer { loading = false }
        do { let updated = try await read(); guard !Task.isCancelled else { return }; snapshot = updated }
        catch is CancellationError {} catch { failure = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working, !loading, !model.busy else { return }; working = true; model.busy = true; failure = nil
        let owner = model.identity
        operationTask = Task { @MainActor in
            defer { working = false; if model.identity == owner { model.busy = false } }
            do { guard model.identity == owner else { throw CancellationError() }; try await action(); guard model.identity == owner else { return }; await onUpdated() }
            catch is CancellationError {} catch {
                guard model.identity == owner else { return }
                if let updated = try? await read() { snapshot = updated }
                failure = error.localizedDescription
                if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
            }
        }
    }
    private func arrive(_ order: PartnerPickupSuborder) {
        perform {
            arrivals[order.id] = try await model.api.arriveAtPartner(parcelID: parcel.id, orderID: order.id)
            status = "ВВ подтвердил прибытие. После выдачи сверь пакеты и подтверди получение."
        }
    }
    private func confirm(_ order: PartnerPickupSuborder) {
        perform {
            if model.demo {
                let raw: [String: Any] = ["parcel_addresses": [["partner_name": "Демо-партнёр", "id_partner": 1, "user_address": "Учебная улица, 1", "suborders": [["id_order": order.id, "check": order.checked ? 0 : 1, "collected_pkgs": 2]]]]]
                snapshot = try PartnerPickupSnapshot.parse(raw, parcel: parcel)
                status = "Демо: отметка только на экране."
            } else {
                try await model.api.confirmPartnerPickup(parcelID: parcel.id, orderID: order.id, checked: !order.checked, arrival: arrivals[order.id])
                snapshot = try await read()
                status = order.checked ? "ВВ подтвердил снятие отметки." : "ВВ подтвердил получение подзаказа."
            }
        }
    }
}
