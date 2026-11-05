import SwiftUI

struct DeliveryPaymentView: View {
    @EnvironmentObject private var model: AppModel
    let parcel: Parcel
    let onFinished: () -> Void
    @State private var current: Parcel?
    @State private var terminal: [String: Any] = [:]
    @State private var selected: DeliveryPaymentMethod?
    @State private var received = ""
    @State private var loading = true
    @State private var working = false
    @State private var failure: String?
    @State private var review = false
    @State private var reviewedConfirmation: DeliveryPaymentConfirmation?
    @State private var completion: DeliveryCompletion?
    private var value: Parcel { current ?? parcel }
    private var due: Decimal? { DeliveryPaymentRules.amountDue(value.raw) }
    private var paymentWay: Int? { Int(string(value.raw["pay_way"])) }
    private var alreadyPaid: Bool { DeliveryPaymentRules.collectionNotRequired(value.raw) }
    private var receivedAmount: Decimal? { DeliveryPaymentRules.amount(received) }
    private var canComplete: Bool {
        guard !loading, !working, current != nil, let due else { return false }
        if alreadyPaid { return true }
        guard paymentWay.map({ [1, 3, 4].contains($0) }) == true else { return false }
        guard let selected else { return false }
        return selected != .cash || (receivedAmount.map { $0 >= due } == true)
    }
    var body: some View {
        Group {
            if let completion {
                if completion.needsReceipt {
                    ReceiptPhotosView(parcelID: completion.parcelID, label: parcel.fullNumber, afterCompletion: true, onFinished: onFinished)
                } else {
                    CourierPage("Заказ доставлен", subtitle: "Заказ \(parcel.fullNumber)") {
                        CourierCard {
                            Label("ВВ подтвердил доставку", systemImage: "checkmark.circle").foregroundStyle(Palette.success)
                            Text("Фактический способ оплаты пока не получен. Обнови архив: если ВВ подтвердит терминальную оплату, там появится фото чека.").font(.subheadline).foregroundStyle(Palette.muted)
                        }
                        Button("Готово") { onFinished() }.buttonStyle(CourierButtonStyle(primary: true))
                    }
                }
            } else {
                CourierPage("Завершение заказа", subtitle: "Заказ \(parcel.fullNumber)") {
                    if model.demo { DemoBanner() }
                    if loading { CourierCard { ProgressView("Проверяем оплату…") } }
                    if let failure { CourierErrorCard(message: failure) { Task { await load() } } }
                    if let due {
                        CourierCard {
                            Text(alreadyPaid ? "Сумма заказа" : "К оплате").font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("payment.screen")
                            Text(display(due)).font(.title2.weight(.semibold)).monospacedDigit().accessibilityIdentifier("payment.amount")
                            if alreadyPaid {
                                Label("Оплата не требуется при вручении", systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(Palette.success)
                            } else {
                                Text("Выбери, как покупатель фактически оплатил заказ.").font(.subheadline).foregroundStyle(Palette.muted)
                            }
                        }
                        if paymentWay == 9 {
                            CourierCard { Text("Проверка оплаты по ссылке пока не поддерживается. Завершение недоступно, способ оплаты не изменяется.").font(.subheadline).foregroundStyle(Palette.warning) }
                        }
                        if !alreadyPaid && paymentWay != 9 && current != nil {
                            CourierCard("Способ оплаты") {
                                ForEach(DeliveryPaymentRules.methods(terminal: terminal)) { method in
                                    Button { selected = method } label: {
                                        HStack {
                                            Image(systemName: method == .cash ? "banknote" : method == .terminalQR ? "qrcode" : "creditcard")
                                            Text(method.title).multilineTextAlignment(.leading)
                                            Spacer(minLength: 8)
                                            Image(systemName: selected == method ? "checkmark.circle.fill" : "circle").foregroundStyle(selected == method ? Palette.accent : Palette.muted)
                                        }.font(.subheadline).padding(.vertical, 8)
                                    }.buttonStyle(.plain).disabled(working).accessibilityIdentifier("payment.method." + method.rawValue)
                                }
                            }
                            if selected == .cash {
                                CourierCard("Получено от покупателя") {
                                    TextField("Сумма наличными", text: $received).keyboardType(.decimalPad).font(.title3).monospacedDigit().accessibilityIdentifier("payment.cash-received")
                                    if let amount = receivedAmount, amount >= due { Text("Сдача: " + display(amount - due)).font(.subheadline.weight(.semibold)) }
                                    Text("Подтверждай только после получения денег и выдачи сдачи.").font(.caption).foregroundStyle(Palette.muted)
                                }
                            } else if selected != nil {
                                CourierCard {
                                    Text("Проведи оплату на выданном терминале и дождись успешного чека. Это подтверждение уже выполненной оплаты, повторное списание здесь не запускается.").font(.subheadline).foregroundStyle(Palette.muted)
                                    if let id = DeliveryPaymentRules.assignedSberTerminal(terminal) { Text("Терминал №" + id).font(.caption).monospacedDigit() }
                                }
                            }
                        }
                    }
                    Button(working ? "Подтверждаем…" : alreadyPaid ? "Подтвердить доставку" : "Оплата получена · завершить") {
                        reviewedConfirmation = alreadyPaid ? nil : selected.flatMap { method in due.map { DeliveryPaymentConfirmation(method: method, amountDue: $0, cashReceived: method == .cash ? receivedAmount : nil) } }
                        review = true
                    }.buttonStyle(CourierButtonStyle(primary: true)).disabled(!canComplete).accessibilityIdentifier("payment.complete")
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Отмена") { onFinished() }.disabled(working) }
                .confirmationDialog(alreadyPaid ? "Покупатель получил заказ?" : "Покупатель получил заказ и оплата выполнена?", isPresented: $review, titleVisibility: .visible) {
                    Button("Подтвердить доставку") { let confirmed = reviewedConfirmation; Task { await complete(confirmed) } }
                } message: { Text(alreadyPaid ? "ВВ получит статус «Доставлен». Повторное получение оплаты не требуется." : "ВВ получит фактический способ оплаты и статус «Доставлен». После оплаты по терминалу откроется фото чека.") }
            }
        }
        .interactiveDismissDisabled(working)
        .task(id: model.identity) {
            current = nil; completion = nil; selected = nil; received = ""
            working = false; loading = true; review = false; reviewedConfirmation = nil; terminal = [:]; failure = nil
            await load()
        }
    }
    private func display(_ amount: Decimal) -> String { money(NSDecimalNumber(decimal: amount).doubleValue) }
    @MainActor private func load() async {
        guard completion == nil, !working else { return }
        let identity = model.identity, api = model.api, demo = model.demo
        loading = true; failure = nil; current = nil
        defer { if model.identity == identity { loading = false } }
        do {
            let refreshed = demo ? parcel : try await api.parcel(parcel.id)
            guard model.identity == identity, !Task.isCancelled else { return }
            guard ["on_the_way", "arrived"].contains(refreshed.status) else { throw CourierError(message: "Статус заказа изменился. Закрой окно и обнови «Мои».") }
            guard let due = DeliveryPaymentRules.amountDue(refreshed.raw) else { throw CourierError(message: "ВВ не сообщил сумму к оплате. Обнови заказ.") }
            guard let way = Int(string(refreshed.raw["pay_way"])), [0, 1, 2, 3, 4, 5, 9].contains(way) else { throw CourierError(message: "ВВ не сообщил способ оплаты. Обнови заказ.") }
            current = refreshed
            if !DeliveryPaymentRules.collectionNotRequired(refreshed.raw) && way != 9 {
                if demo { terminal = ["res": 2, "terminal_id": "12345678", "shopno": 101] }
                else {
                    do { let state = try await api.terminalStatus(); guard model.identity == identity, !Task.isCancelled else { return }; terminal = state }
                    catch { guard model.identity == identity, !Task.isCancelled else { return }; terminal = [:]; failure = "Не удалось проверить назначенный терминал. Обнови данные перед подтверждением оплаты по карте." }
                }
                selected = way == 4 ? .cash : DeliveryPaymentRules.methods(terminal: terminal).first
                if refreshed.isCashPayment && !refreshed.cashWithoutChange && refreshed.cashChange == nil {
                    received = ""
                } else { received = DeliveryPaymentRules.decimalString(refreshed.cashChange?.tendered ?? due) }
            }
        } catch { guard model.identity == identity, !Task.isCancelled else { return }; failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } }
    }
    @MainActor private func complete(_ confirmation: DeliveryPaymentConfirmation?) async {
        guard canComplete, !model.busy else { return }
        let identity = model.identity, api = model.api, demo = model.demo
        working = true; model.busy = true; failure = nil
        defer { if model.identity == identity { working = false; model.busy = false } }
        do {
            let result: DeliveryCompletion
            if demo {
                let body = try DeliveryPaymentRules.completionBody(parcel: value.raw, courierID: "demo", confirmation: confirmation, terminal: terminal, flags: [100])
                model.demoMine.removeAll { $0.id == parcel.id }
                result = DeliveryCompletion(parcelID: parcel.id, payWay: Int(number(body["pay_way"])))
            } else { result = try await api.completeDelivery(parcel.id, confirmation: confirmation) }
            guard model.identity == identity, !Task.isCancelled else { return }
            if result.needsReceipt || result.payWay == nil { completion = result }
            else { onFinished() }
        } catch { guard model.identity == identity, !Task.isCancelled else { return }; failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } }
    }
}
