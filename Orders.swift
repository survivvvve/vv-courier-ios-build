import SwiftUI

extension CourierAPI {
    /// Reuse the paginated feed. VV may return an overlapping category dictionary
    /// in `total`; treating that dictionary as a number would create a false zero.
    func orderCount(_ feed: Feed) async throws -> Int? {
        try await self.feed(feed).total
    }
}

struct OrdersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var orders: [Parcel] = []
    @State private var counts: [String: Int] = [:]
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var generation = UUID()
    @State private var countGeneration = UUID()
    @State private var countsScope = ""
    @State private var assembly = "all"
    @State private var selected: Parcel?
    @State private var mapSelection: String?
    @State private var mapShops: [[String: Any]] = []
    @State private var loadedKey: String?
    private var countKey: String { model.shopScopeKey + ":\(model.revision)" }
    private var loadKey: String { countKey + ":" + model.selectedFeed.rawValue + ":" + assembly }
    private var cameraScope: String { model.shopScopeKey + ":" + model.selectedFeed.rawValue + ":" + assembly }
    private var mapEntries: [ParcelMapEntry] { ParcelMapEntry.entries(orders, feed: model.selectedFeed, shopColors: Dictionary(model.shops.compactMap { shop in shop.color.map { (shop.id, $0) } }, uniquingKeysWith: { _, latest in latest })) }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { listProxy in
                VStack(spacing: 0) {
                    headerControls
                    OrdersInlineMap(entries: mapEntries, mapShops: mapShops, cameraScope: cameraScope, loading: loading, dataIsCurrent: loaded && loadedKey == loadKey, selectedID: $mapSelection)
                        .frame(height: min(160, max(120, geometry.size.height * 0.25)))
                        .padding(.horizontal, 14).padding(.bottom, 8)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            Color.clear.frame(height: 0).id("orders.start")
                            if model.sessionExpired { ReauthenticationCard() }
                            if model.selectedFeed == .mine { BatchDepartureControl { await reload() }; Text("Взятые заказы со всех магазинов").font(.caption2).foregroundStyle(Palette.muted) }
                            if loading { ProgressView("Обновляем…").font(.caption).frame(maxWidth: .infinity).padding(.vertical, 8) }
                            if let failure { CourierErrorCard(message: failure) { Task { await reload() } } }
                            if loaded && orders.isEmpty && failure == nil {
                                CourierEmpty(title: "Заказов пока нет", message: model.selectedFeed == .mine ? "Взятые заказы появятся здесь." : "Для выбранного магазина и раздела ВВ пока не показывает заказы.", symbol: "shippingbox")
                            }
                            ForEach(mapEntries) { entry in
                                Button {
                                    mapSelection = entry.id
                                    selected = entry.parcel
                                } label: {
                                    CourierCard {
                                        ParcelSummary(parcel: entry.parcel, assembly: model.selectedFeed == .assembly, listNumber: entry.number, markerColor: entry.colorName)
                                        if model.selectedFeed != .mine && !entry.parcel.buyerComments.isEmpty {
                                            OrderBuyerComments(comments: entry.parcel.buyerComments)
                                                .accessibilityElement(children: .contain).accessibilityIdentifier("order.buyer-comments." + entry.id)
                                        }
                                    }.overlay(RoundedRectangle(cornerRadius: 14).stroke(mapSelection == entry.id ? parcelMapColor(entry.colorName) : .clear, lineWidth: 2))
                                }.buttonStyle(.plain).id(entry.id).accessibilityIdentifier("order.\(entry.id)")
                                    .accessibilityValue(mapSelection == entry.id ? "Выбран на карте" : "")
                            }
                        }.padding(.horizontal, 14).padding(.bottom, 16)
                    }.refreshable { await reload(); await loadCounts(); await model.bootstrap() }
                }
                .onChange(of: mapSelection) { _, id in if let id { withAnimation(.easeInOut(duration: 0.2)) { listProxy.scrollTo(id, anchor: .top) } } }
                .onChange(of: cameraScope) { _, _ in mapSelection = nil; listProxy.scrollTo("orders.start", anchor: .top) }
            }
        }
        .background(Palette.background)
        .courierBrandHeader()
        .safeAreaInset(edge: .top, spacing: 0) { ColdControlNotice() }
        .navigationTitle("Заказы").navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) { await reload() }
        .task(id: model.notificationTarget?.id) { await openNotificationOrder() }
        .task(id: countKey) { await loadCounts() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { ScheduleView() } label: { Image(systemName: "calendar").frame(width: 30, height: 40) }.accessibilityLabel("График смен").accessibilityIdentifier("dashboard.schedule")
                Button { Task { await reload(); await loadCounts() } } label: { Image(systemName: "arrow.clockwise").frame(width: 30, height: 40) }.disabled(loading).accessibilityLabel("Обновить заказы")
            }
        }
        .sheet(item: $selected) { parcel in NavigationStack { ParcelDetailView(initial: parcel, source: model.selectedFeed) } }
    }
    private var headerControls: some View {
        VStack(spacing: 4) {
            if model.demo { DemoBanner() }
            ShopScopeButton()
            ShiftControlBar()
            Picker("Раздел заказов", selection: $model.selectedFeed) {
                ForEach(Feed.allCases) { feed in Text(feed.title + (counts[feed.rawValue].map { " \($0)" } ?? "")).tag(feed).accessibilityLabel(feed.title) }
            }.pickerStyle(.segmented).accessibilityIdentifier("orders.feed").padding(.top, 3)
            if model.selectedFeed == .assembly {
                HStack {
                    Text("Показать").font(.caption).foregroundStyle(Palette.muted)
                    Spacer()
                    Picker("Состояние сборки", selection: $assembly) {
                        Text("Все").tag("all"); Text("Собираются").tag("building"); Text("Ожидают сборки").tag("waiting"); Text("Времянки").tag("sloted")
                    }.pickerStyle(.menu).accessibilityIdentifier("orders.assembly")
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 6).background(Palette.background)
    }
    @MainActor private func openNotificationOrder() async {
        guard let target = model.notificationTarget, !model.demo,
              model.session?.courierID == target.courierID else { return }
        let identity = model.identity, client = model.api
        do {
            let parcel = try await client.parcel(target.parcelID)
            guard !Task.isCancelled, model.identity == identity,
                  model.session?.courierID == target.courierID,
                  model.notificationTarget?.id == target.id else { return }
            selected = parcel
            mapSelection = parcel.id
            model.notificationTarget = nil
        } catch is CancellationError {} catch {
            guard model.identity == identity, model.notificationTarget?.id == target.id else { return }
            await reload()
            guard !Task.isCancelled, model.identity == identity,
                  model.notificationTarget?.id == target.id else { return }
            failure = "Не удалось открыть экспресс из уведомления. " + error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
            model.notificationTarget = nil
        }
    }
    private func reload() async {
        let id = UUID(), key = loadKey; generation = id; loading = true; failure = nil; loaded = false
        if loadedKey != key { orders = []; mapShops = [] }
        defer { if generation == id { loading = false } }
        let feed = model.selectedFeed
        if model.demo {
            orders = model.demoOrders(feed); counts[feed.rawValue] = orders.count
            let demoShops: [[String: Any]] = [["shopno": 101, "latitude": 60.073, "longitude": 30.335, "color": "green"], ["shopno": 202, "latitude": 60.078, "longitude": 30.34, "color": "green"]]
            mapShops = demoShops.filter { model.selectedShopID == nil || Int(number($0["shopno"])) == model.selectedShopID }
            loadedKey = key; loaded = true; return
        }
        guard !model.sessionExpired else { return }
        let client = model.api, mode = assembly
        do {
            let result = try await client.feed(feed, assembly: mode)
            guard generation == id, !Task.isCancelled else { return }
            orders = result.parcels; mapShops = result.mapShops; if feed != .assembly || mode == "all" { counts[feed.rawValue] = result.total }; loadedKey = key; loaded = true
        } catch is CancellationError { }
        catch { if generation == id { failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } } }
    }
    private func loadCounts() async {
        let id = UUID(), scope = model.shopScopeKey; countGeneration = id
        if countsScope != scope { counts = [:]; countsScope = scope }
        if model.demo { counts = Dictionary(uniqueKeysWithValues: Feed.allCases.map { ($0.rawValue, model.demoOrders($0).count) }); return }
        guard !model.sessionExpired else { counts = [:]; return }
        let client = model.api
        async let available = try? client.orderCount(.available)
        async let assembly = try? client.orderCount(.assembly)
        async let mine = try? client.orderCount(.mine)
        let result = await [available, assembly, mine]
        guard countGeneration == id, !Task.isCancelled else { return }
        for (feed, total) in zip(Feed.allCases, result) { if let total { counts[feed.rawValue] = total } }
    }
}

struct ParcelSummary: View {
    let parcel: Parcel
    var assembly = false
    var listNumber: Int? = nil
    var markerColor: String? = nil
    private var numberStyle: AnyShapeStyle {
        markerColor.map { AnyShapeStyle(parcelMapColor($0)) } ?? AnyShapeStyle(Palette.muted)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let listNumber {
                    Text(String(listNumber)).font(.system(size: 10, weight: .bold)).foregroundStyle(numberStyle)
                        .frame(minWidth: 19, minHeight: 19).background(numberStyle.opacity(0.1), in: Circle())
                }
                Text(parcel.label).font(.subheadline.weight(.semibold)).monospacedDigit()
                if parcel.express { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(Palette.accent).accessibilityLabel("Экспресс") }
                if parcel.water { Image(systemName: "drop").font(.caption2).foregroundStyle(Palette.muted).accessibilityLabel("Вода") }
                if parcel.eggs { Image(systemName: "oval.portrait").font(.caption2).foregroundStyle(Palette.muted).accessibilityLabel("Яйца") }
                Spacer(minLength: 4)
                if !parcel.deliverySlot.isEmpty { Text(parcel.deliverySlot).font(.caption).foregroundStyle(Palette.muted).monospacedDigit() }
                else { ParcelTimer(deadline: parcel.deadline) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }
            Text(parcel.streetLine.isEmpty ? "Адрес уточняется" : parcel.streetLine).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            if !parcel.detailsLine.isEmpty { Text(parcel.detailsLine).font(.subheadline).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Text("\(parcel.weight, specifier: "%.3f") кг · \(money(parcel.reward))")
                Spacer(minLength: 4)
                if assembly {
                    if let started = parcel.assemblyStarted {
                        TimelineView(.periodic(from: .now, by: 30)) { context in Text("Собирают \(max(0, Int(context.date.timeIntervalSince(started) / 60))) мин") }
                    } else { Text("Ожидает сборки") }
                } else if let shop = parcel.shopID { Text("№\(shop)") }
            }.font(.caption).foregroundStyle(Palette.muted)
        }
    }
}

func parcelCountdown(seconds: Int) -> String {
    let value = abs(seconds), sign = seconds < 0 ? "−" : ""
    if value >= 86400 { return "\(sign)\(value / 86400) д \(value % 86400 / 3600) ч" }
    if value >= 3600 { return String(format: "%@%d:%02d:%02d", sign, value / 3600, value % 3600 / 60, value % 60) }
    return String(format: "%@%d:%02d", sign, value / 60, value % 60)
}

struct ParcelTimer: View {
    let deadline: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let deadline {
                let seconds = Int(deadline.timeIntervalSince(context.date))
                Text(parcelCountdown(seconds: seconds)).font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(seconds < 15 * 60 ? Palette.danger : seconds < 30 * 60 ? Palette.warning : Palette.success)
            }
        }
    }
}

struct ParcelDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let initial: Parcel
    let source: Feed
    @State private var parcel: Parcel?
    @State private var loading = false
    @State private var failure: String?
    @State private var taking = false
    @State private var inspectingAfter: Bool?
    @State private var inspectionMode = 0
    @State private var goods: [[String: Any]]?
    @State private var goodsError: String?
    @State private var goodsLoading = false
    @State private var contactPresented = false
    private var current: Parcel { parcel ?? initial }
    var body: some View {
        CourierPage("Заказ \(current.fullNumber)", subtitle: current.shopID.map { "Магазин №\($0)" }, artwork: 2) {
            if model.demo { DemoBanner() }
            CourierCard {
                HStack { Text(current.statusTitle).font(.subheadline.weight(.semibold)).accessibilityIdentifier("order.detail"); Spacer(); ParcelTimer(deadline: current.deadline) }
                Text(current.address.isEmpty ? "Адрес не указан" : current.address).font(.headline).textSelection(.enabled)
                if !current.doorphone.isEmpty { Label("Домофон: \(current.doorphone)", systemImage: "bell") }
                HStack {
                    CourierMetric(title: "Вознаграждение", value: money(current.reward))
                    CourierMetric(title: "Вес", value: String(format: "%.3f кг", current.weight))
                }
                let method = current.effectivePaymentWay.flatMap { [0: "Онлайн", 1: "Офлайн", 2: "Без оплаты", 3: "Терминал", 4: "Наличные", 5: "Безналичный расчёт", 9: "По ссылке"][$0] } ?? "Уточняется"
                Text("Способ оплаты: \(method)").font(.caption).foregroundStyle(Palette.muted)
                if let sum = current.raw["pay_summ"], number(sum) > 0 { Text("К оплате: \(money(number(sum)))").font(.subheadline) }
                if let change = current.cashChange {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Сдача: " + money(NSDecimalNumber(decimal: change.change).doubleValue), systemImage: "banknote")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent).accessibilityElement(children: .combine).accessibilityIdentifier("order.cash-change")
                        Spacer(minLength: 8)
                        Text("С " + money(NSDecimalNumber(decimal: change.tendered).doubleValue)).font(.caption).foregroundStyle(Palette.muted)
                    }
                } else if current.cashWithoutChange {
                    Label("Без сдачи", systemImage: "banknote").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent).accessibilityElement(children: .combine).accessibilityIdentifier("order.cash-exact")
                }
                if !current.deliverySlot.isEmpty { Text("Интервал: \(current.deliverySlot)").font(.subheadline) }
            }
            ParcelPackagesCard(parcel: current)
            if source == .mine && truth(current.raw["has_partner_order"]) { CourierCard { PartnerPickupLink(parcel: current) { await reload() } } }
            ReceiptPhotosCard(parcel: current)
            if loading { ProgressView("Обновляем заказ…").frame(maxWidth: .infinity) }
            if let failure { CourierErrorCard(message: failure) { Task { await reload() } } }
            if source == .available && !["pickuped", "on_the_way", "arrived", "on_return", "delivered", "returned"].contains(current.status) {
                Button("Взять заказ") { taking = true }.buttonStyle(CourierButtonStyle(primary: true)).disabled(model.busy || loading || model.sessionExpired).accessibilityIdentifier("order.take")
            }
            if source == .mine {
                CourierCard("Работа с заказом") {
                    ParcelActionsView(parcel: current) { await reload() }
                    Button { openInspection(after: current.status != "pickuped") } label: { Label(current.status == "pickuped" ? "Все пакеты перед выездом" : "Проверить пакеты у покупателя", systemImage: "qrcode.viewfinder") }.buttonStyle(CourierButtonStyle()).disabled(model.busy)
                    Button { contactPresented = true } label: { Label("Связаться с покупателем", systemImage: "phone") }.buttonStyle(CourierButtonStyle()).disabled(model.busy)
                }
            }
            if !current.buyerComments.isEmpty {
                CourierCard("Комментарий покупателя") {
                    ForEach(current.buyerComments, id: \.self) { Text($0).font(.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("order.buyer-comments.detail")
            }
            if !current.courierComments.isEmpty {
                CourierCard("Комментарий курьера к адресу") {
                    ForEach(current.courierComments, id: \.self) { Text($0).font(.subheadline).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("order.courier-comments.detail")
            }
            CourierCard {
                DisclosureGroup("Состав заказа") {
                    VStack(alignment: .leading, spacing: 12) {
                        if goodsLoading { ProgressView() }
                        if let goodsError { Text(goodsError).font(.caption).foregroundStyle(Palette.warning) }
                        if let goods {
                            ForEach(goods.indices, id: \.self) { index in
                                let row = goods[index]
                                HStack { Text(string(row["name"] ?? row["name_tov"] ?? row["good_name"] ?? row["goods_name"])); Spacer(); Text(string(row["quantity"] ?? row["count"] ?? row["amount"])).foregroundStyle(Palette.muted) }.font(.subheadline)
                            }
                            if goods.isEmpty { Text("ВВ не указал товары").font(.caption).foregroundStyle(Palette.muted) }
                        }
                        Button("Загрузить товары") { Task { await loadGoods() } }.buttonStyle(CourierButtonStyle()).disabled(goodsLoading)
                    }.padding(.top, 10)
                }
            }
            Button("Обновить заказ") { Task { await reload() } }.buttonStyle(CourierButtonStyle()).disabled(loading || model.busy)
        }.navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Готово") { dismiss() }.accessibilityIdentifier("order.close") }
            .modifier(CourierErrors())
            .task(id: model.revision) { await reload() }.refreshable { await reload() }
            .confirmationDialog("Взять заказ \(current.fullNumber)?", isPresented: $taking, titleVisibility: .visible) {
                Button("Взять") {
                    let value = current, client = model.api
                    model.perform {
                        if model.demo { var picked = value; picked.status = "pickuped"; model.demoMine.append(picked); model.demoTaken.insert(value.id) }
                        else { try await client.take(value.id) }
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: Binding(get: { inspectingAfter != nil }, set: { if !$0 { inspectingAfter = nil } })) {
                NavigationStack { ParcelInspectionView(parcel: current, after: inspectingAfter ?? false, mode: inspectionMode) { inspectingAfter = nil; Task { await reload() } }.toolbar { Button("Готово") { inspectingAfter = nil }.disabled(model.busy) }.modifier(CourierErrors()) }
            }
            .sheet(isPresented: $contactPresented) { NavigationStack { ContactBuyerView(parcel: current).modifier(CourierErrors()) } }
    }
    private func reload() async {
        loading = true; failure = nil
        defer { loading = false }
        if model.demo {
            if source == .mine { if let found = model.demoMine.first(where: { $0.id == initial.id }) { parcel = found } else { dismiss() } }
            else { parcel = initial }
            return
        }
        do { let value = try await model.api.parcel(initial.id); guard !Task.isCancelled else { return }; parcel = value }
        catch is CancellationError { }
        catch { failure = error.localizedDescription; if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true } }
    }
    private func openInspection(after: Bool) {
        let value = current, client = model.api
        model.perform {
            let mode = model.demo ? 1 : try await client.inspectionRequirement(parcelID: value.id, after: after)
            if mode == 0 { model.error = "ВВ не требует проверки пакетов для этого этапа."; return }
            inspectionMode = mode; inspectingAfter = after
        }
    }
    private func loadGoods() async {
        guard !goodsLoading else { return }; goodsLoading = true; goodsError = nil
        defer { goodsLoading = false }
        if model.demo { goods = [["name": "Демонстрационный товар", "quantity": 2], ["name": "Учебный товар", "quantity": 1]]; return }
        do {
            let result = try await model.api.request(CourierAPI.root + "/v1/courier/get_goods/" + current.id)
            if let rows = result as? [[String: Any]] { goods = rows }
            else if let data = result as? [String: Any], let rows = data["goods"] as? [[String: Any]] ?? data["items"] as? [[String: Any]] { goods = rows }
            else { throw CourierError(message: "Состав заказа сейчас недоступен. Повтори загрузку позже.") }
        } catch { goodsError = error.localizedDescription }
    }
}

struct ContactBuyerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let parcel: Parcel
    @State private var reasons: [[String: Any]] = []
    @State private var selected: String?
    @State private var custom = ""
    @State private var phone: String?
    @State private var failure: String?
    @State private var loading = false
    var body: some View {
        CourierPage("Связаться с покупателем", subtitle: "Заказ \(parcel.fullNumber)", artwork: 3) {
            if model.demo { DemoBanner() }
            CourierCard {
                Text("Укажи причину звонка. ВВ откроет номер на ограниченное время.").font(.subheadline).foregroundStyle(Palette.muted)
                if loading { ProgressView() }
                if let failure { Text(failure).foregroundStyle(Palette.warning).font(.subheadline) }
                ForEach(reasons.indices, id: \.self) { index in
                    let row = reasons[index]
                    Button { selected = string(row["id"]) } label: { HStack { Text(string(row["phone_call_reason"])); Spacer(); if selected == string(row["id"]) { Image(systemName: "checkmark.circle.fill") } } }.padding(.vertical, 7)
                }
                if selected == "0" { TextField("Причина звонка", text: $custom).padding(12).background(Palette.field, in: RoundedRectangle(cornerRadius: 10)) }
                Button("Показать номер") { reveal() }.buttonStyle(CourierButtonStyle(primary: true)).disabled(loading || selected == nil || (selected == "0" && custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if let phone {
                    if model.demo { Text("Демо: реальный звонок не выполняется").font(.caption) }
                    else if let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) { Link(destination: url) { Label("Позвонить", systemImage: "phone.fill") }.buttonStyle(CourierButtonStyle(primary: true)) }
                }
            }
        }.navigationBarTitleDisplayMode(.inline).toolbar { Button("Готово") { dismiss() } }.task { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        if model.demo { reasons = [["id": 1, "phone_call_reason": "Уточнить адрес"], ["id": 0, "phone_call_reason": "Другая причина"]]; return }
        do {
            let result = try await model.api.request(CourierAPI.root + "/v1/courier/get_phone_call_reasons")
            if let rows = result as? [[String: Any]] { reasons = rows }
            else if let data = result as? [String: Any], let rows = data["reasons"] as? [[String: Any]] ?? data["phone_call_reasons"] as? [[String: Any]] { reasons = rows }
            else { throw CourierError(message: "Не удалось загрузить причины звонка.") }
        } catch { failure = error.localizedDescription }
    }
    private func reveal() {
        guard let selected else { return }
        let reason = selected == "0" ? custom : string(reasons.first { string($0["id"]) == selected }?["phone_call_reason"])
        let client = model.api
        model.perform {
            if model.demo { phone = "demo"; return }
            guard let courier = Int(model.session?.courierID ?? ""), let id = Int(parcel.id), let reasonID = Int(selected) else { throw CourierError(message: "Не удалось определить заказ.") }
            _ = try await client.request(CourierAPI.root + "/v1/courier/set_phone_call_reason", body: ["courier_id": courier, "parcel_id": id, "reason_id": reasonID, "call_reason": reason])
            let updated = try await client.parcel(parcel.id)
            let number = string(updated.raw["phone"])
            guard !number.isEmpty else { throw CourierError(message: "ВВ пока не открыл номер. Обнови заказ позже.") }
            phone = number
        }
    }
}

struct OrderBuyerComments: View {
    let comments: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Комментарий покупателя").font(.caption2.weight(.semibold)).foregroundStyle(Palette.muted)
            ForEach(comments, id: \.self) { Text($0).font(.subheadline).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Palette.accentSurface, in: RoundedRectangle(cornerRadius: 9))
    }
}
