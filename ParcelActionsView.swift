import SwiftUI

struct ParcelActionsView: View {
    @EnvironmentObject private var model: AppModel
    let parcel: Parcel
    let refresh: () async -> Void
    @State private var selection: ParcelActionIntent?
    @State private var reasons: [[String: Any]] = []
    @State private var showReasons = false
    @State private var reasonIntent: ParcelActionIntent?
    @State private var preparedReason: ParcelActionIntent?
    @State private var customReason = ""
    @State private var editingCustomReason = false
    @State private var paymentPresented = false
    private let titles = ["start": "В путь", "arrived": "На месте", "deliver": "Заказ доставлен", "cancel": "Отказ / возврат", "returned": "Вернул на магазин", "resume": "Продолжить доставку"]
    private var actions: [String] {
        switch parcel.status {
        case "pickuped": return ["cancel"]
        case "on_the_way": return ["arrived", "deliver", "cancel"]
        case "arrived": return ["deliver", "cancel"]
        case "on_return": return ["returned", "resume"]
        case "awaiting_return", "awaiting_deletion": return ["returned"]
        default: return []
        }
    }
    var body: some View {
        VStack(spacing: 10) {
            if parcel.status == "pickuped" { BatchDepartureControl(refresh: refresh) }
            ForEach(actions, id: \.self) { action in
                Button(titles[action] ?? action) {
                    let intent = ParcelActionIntent(action: action, parcelID: parcel.id, expectedStatus: parcel.status, identity: model.identity, demo: model.demo)
                    reasonIntent = nil; preparedReason = nil; customReason = ""; editingCustomReason = false
                    if action == "cancel" {
                        let client = model.api
                        model.perform {
                            let available = intent.demo ? [["id": 1, "return_reason": "Демонстрационный отказ"], ["id": 0, "return_reason": "Другое"]] : try await client.reasons(before: intent.expectedStatus == "pickuped")
                            try intent.validate(identity: model.identity, parcelID: parcel.id, status: parcel.status)
                            guard !Task.isCancelled else { throw CancellationError() }
                            reasons = available; reasonIntent = intent
                            showReasons = true
                        }
                    } else if action == "deliver" { paymentPresented = true }
                    else { selection = intent }
                }.buttonStyle(CourierButtonStyle(primary: action == actions.first)).disabled(model.busy || model.sessionExpired).accessibilityIdentifier("order.action.\(action)")
            }
        }
        .sheet(isPresented: $paymentPresented) {
            NavigationStack {
                DeliveryPaymentView(parcel: parcel) {
                    paymentPresented = false
                    model.revision += 1
                    Task { await refresh() }
                }
            }
        }
        .confirmationDialog("Заказ \(parcel.fullNumber): \(titles[selection?.action ?? ""] ?? "")?", isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } }), titleVisibility: .visible, presenting: selection) { intent in
            Button("Подтвердить") {
                selection = nil
                let client = model.api
                model.perform {
                    try intent.validate(identity: model.identity, parcelID: parcel.id, status: parcel.status)
                    guard !Task.isCancelled else { throw CancellationError() }
                    if intent.demo {
                        if ["deliver", "returned", "cancel"].contains(intent.action) { model.demoMine.removeAll { $0.id == intent.parcelID } }
                        else if let index = model.demoMine.firstIndex(where: { $0.id == intent.parcelID }) {
                            model.demoMine[index].status = ["start": "on_the_way", "arrived": "arrived", "resume": "on_the_way"][intent.action] ?? intent.expectedStatus
                        }
                    } else { try await client.orderAction(intent.parcelID, action: intent.action, reasonID: intent.reasonID, reasonText: intent.reasonText, expectedStatus: intent.expectedStatus) }
                    guard model.identity == intent.identity, !Task.isCancelled else { throw CancellationError() }
                    await refresh()
                }
            }
        } message: { intent in Text(intent.reasonText ?? "Действие изменит статус заказа в ВВ. Обязательные проверки и оплата должны быть выполнены.") }
        .sheet(isPresented: $showReasons, onDismiss: {
            if let intent = preparedReason, intent.identity == model.identity, intent.parcelID == parcel.id, intent.expectedStatus == parcel.status { selection = intent }
            preparedReason = nil
        }) {
            NavigationStack {
                CourierPage("Причина отказа", subtitle: "Заказ \(parcel.fullNumber)", artwork: 3) {
                    if reasons.isEmpty { CourierEmpty(title: "Причины недоступны", message: "ВВ не вернул доступные причины. Обнови заказ.", symbol: "exclamationmark.circle") }
                    if editingCustomReason {
                        CourierCard("Другое") {
                            TextField("Напиши конкретную причину возврата", text: $customReason, axis: .vertical).lineLimit(3...7).accessibilityIdentifier("return.custom-reason")
                            Button("Продолжить") {
                                guard var intent = reasonIntent else { return }
                                intent.reasonID = "0"; intent.reasonText = customReason.trimmingCharacters(in: .whitespacesAndNewlines)
                                preparedReason = intent; showReasons = false
                            }.buttonStyle(CourierButtonStyle(primary: true)).disabled(customReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("return.custom-confirm")
                            Button("К списку причин") { editingCustomReason = false }.buttonStyle(CourierButtonStyle())
                        }
                    } else {
                        ForEach(reasons.indices, id: \.self) { index in
                            Button(string(reasons[index]["return_reason"] ?? reasons[index]["name"] ?? reasons[index]["text"])) {
                                guard var intent = reasonIntent else { return }
                                if integer(reasons[index]["id"]) == 0 { editingCustomReason = true; return }
                                intent.reasonID = string(reasons[index]["id"])
                                preparedReason = intent; showReasons = false
                            }.buttonStyle(CourierButtonStyle())
                        }
                    }
                }.toolbar { Button("Отмена") { preparedReason = nil; showReasons = false } }.modifier(CourierErrors())
            }
        }
        .onChange(of: model.identity) { _ in resetIntent() }
        .onChange(of: parcel.id + ":" + parcel.status) { _ in resetIntent() }
    }

    private func resetIntent() {
        selection = nil; reasonIntent = nil; preparedReason = nil; reasons = []
        showReasons = false; paymentPresented = false; customReason = ""; editingCustomReason = false
    }
}
