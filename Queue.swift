import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var model: AppModel
    @State private var catalog: [QueueSummary] = []
    @State private var selectedID: String?
    @State private var detail: QueueSection?
    @State private var loading = false
    @State private var detailLoading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var detailFailure: String?
    @State private var catalogGeneration = UUID()
    @State private var detailGeneration = UUID()
    @State private var detailTask: Task<Void, Never>?
    @State private var pickerPresented = false
    @State private var actionQueue: QueueSection?
    @State private var actionScope = ""
    @State private var qr = ""
    @State private var scanning = false
    @State private var confirmation = false
    @State private var demoJoined = Set<String>()
    private var selectedSummary: QueueSummary? { catalog.first { $0.id == selectedID } }

    var body: some View {
        CourierPage("Очередь") {
            if model.demo { DemoBanner() }
            ShopScopeButton()
            if !catalog.isEmpty {
                Button { pickerPresented = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedSummary?.title ?? "Выбери очередь").font(.headline)
                            if let subtitle = selectedSummary?.shopSubtitle { Text(subtitle).font(.caption).foregroundStyle(Palette.muted) }
                        }
                        Spacer(); Image(systemName: "chevron.down").font(.caption)
                    }
                }.buttonStyle(CourierButtonStyle()).disabled(loading || model.busy).accessibilityIdentifier("queue.selector")
            }
            if loading { ProgressView("Обновляем очереди…").frame(maxWidth: .infinity) }
            if let failure { CourierErrorCard(message: failure) { Task { await reloadAll() } } }
            if loaded && catalog.isEmpty && failure == nil {
                CourierEmpty(title: "Нет доступных очередей", message: "ВВ пока не показывает очереди для выбранных магазинов.", symbol: "person.2")
            }
            if detailLoading { ProgressView("Загружаем выбранную очередь…").frame(maxWidth: .infinity) }
            if let detailFailure { CourierErrorCard(message: detailFailure) { select(selectedID) } }
            if let detail, detail.id == selectedID { queueCard(detail) }
            Button { Task { await reloadAll() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .buttonStyle(CourierButtonStyle()).disabled(loading || detailLoading || model.busy).accessibilityIdentifier("queue.refresh")
        }
        .courierBrandHeader()
        .refreshable { await reloadAll() }
        .task(id: model.shopScopeKey + ":\(model.revision)") { await reloadAll() }
        .sheet(isPresented: $pickerPresented) { queuePicker }
        .sheet(isPresented: $scanning, onDismiss: { if !qr.isEmpty && actionQueue != nil { confirmation = true } }) {
            NavigationStack {
                QRScanner(onCode: { qr = $0; scanning = false }, onError: { model.error = $0; scanning = false })
                    .navigationTitle("QR очереди")
                    .toolbar { Button("Отмена") { qr = ""; actionQueue = nil; scanning = false } }
                    .modifier(CourierErrors())
            }
        }
        .confirmationDialog(actionQueue?.people.contains(where: \.isMe) == true ? "Выйти из очереди?" : "Встать в очередь?", isPresented: $confirmation, titleVisibility: .visible) {
            Button("Подтвердить") { confirmAction() }
        } message: { Text(actionQueue?.title ?? "") }
    }

    private func queueCard(_ queue: QueueSection) -> some View {
        let own = queue.people.firstIndex(where: \.isMe)
        return CourierCard {
            HStack {
                Label("Курьеров: \(queue.people.count)", systemImage: "person.2").font(.subheadline).accessibilityIdentifier("queue.detail")
                Spacer()
                Text("Заказов: \(queue.orders)").font(.subheadline.weight(.semibold)).monospacedDigit().accessibilityIdentifier("queue.orders")
            }
            Divider()
            if queue.people.isEmpty {
                Text("В очереди никого нет").font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("queue.empty")
            } else {
                ForEach(Array(queue.people.enumerated()), id: \.element.id) { index, person in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted).frame(width: 22, alignment: .leading)
                        Text(person.name + (person.isMe ? " · ты" : "")).font(.subheadline).fontWeight(person.isMe ? .semibold : .regular)
                        Spacer(minLength: 8)
                        Text("\(person.taken)/\(person.limit)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }.padding(.vertical, 6)
                        .padding(.horizontal, person.isMe ? 8 : 0)
                        .background(Palette.success.opacity(person.isMe ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .combine).accessibilityIdentifier("queue.person.\(person.id)")
                    if index < queue.people.count - 1 { Divider() }
                }
            }
            if let own { Text("Твоя позиция: \(own + 1)").font(.caption).foregroundStyle(Palette.success) }
            Button(own == nil ? "Встать в очередь" : "Выйти из очереди") {
                actionQueue = queue; actionScope = model.shopScopeKey; qr = ""
                if own == nil && queue.requiresQR { scanning = true } else { confirmation = true }
            }.buttonStyle(CourierButtonStyle(primary: own == nil)).disabled(model.busy || model.sessionExpired)
                .accessibilityIdentifier(own == nil ? "queue.join" : "queue.leave")
        }
    }

    private var queuePicker: some View {
        NavigationStack {
            List(catalog) { summary in
                Button {
                    pickerPresented = false
                    select(summary.id)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(summary.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                            HStack(spacing: 10) {
                                Text("Заказов: \(summary.orders)")
                                Text("Курьеров: \(summary.courierCount)")
                            }.font(.caption).foregroundStyle(Palette.muted)
                            if let subtitle = summary.shopSubtitle { Text(subtitle).font(.caption).foregroundStyle(Palette.muted) }
                        }
                        Spacer()
                        if summary.id == selectedID { Image(systemName: "checkmark").foregroundStyle(Palette.success) }
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("queue.choice.\(summary.id)")
            }
            .navigationTitle("Выбери очередь").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Готово") { pickerPresented = false } }
        }.presentationDetents([.medium, .large])
    }

    private func select(_ id: String?) {
        guard let id, catalog.contains(where: { $0.id == id }) else { return }
        detailTask?.cancel()
        selectedID = id; detail = nil; detailFailure = nil; detailGeneration = UUID()
        detailTask = Task { await loadDetail(id) }
    }

    @MainActor private func reloadAll() async {
        let generation = UUID(), scope = model.shopScopeKey, client = model.api, isDemo = model.demo
        actionQueue = nil; confirmation = false; scanning = false; qr = ""
        let shop = model.selectedShopID
        catalogGeneration = generation; detailGeneration = UUID(); detailTask?.cancel()
        loading = true; loaded = false; failure = nil; detailFailure = nil; detail = nil; detailLoading = false
        defer { if catalogGeneration == generation { loading = false } }
        guard isDemo || !model.sessionExpired else { catalog = []; selectedID = nil; return }
        do {
            let summaries: [QueueSummary]
            if isDemo { summaries = QueueDemo.catalog(joined: demoJoined).filter { shop == nil || $0.shops.contains(shop!) } }
            else { summaries = try await client.queueCatalog() }
            guard generation == catalogGeneration, scope == model.shopScopeKey, !Task.isCancelled else { return }
            catalog = summaries; loaded = true
            let choice = selectedID.flatMap { wanted in summaries.first { $0.id == wanted }?.id } ?? summaries.first(where: \.isActive)?.id ?? summaries.first?.id
            selectedID = choice
            if let choice { await loadDetail(choice) }
        } catch is CancellationError { }
        catch {
            guard generation == catalogGeneration, scope == model.shopScopeKey else { return }
            catalog = []; selectedID = nil; failure = error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }

    @MainActor private func loadDetail(_ id: String) async {
        guard let summary = catalog.first(where: { $0.id == id }) else { return }
        let generation = UUID(), scope = model.shopScopeKey, client = model.api, isDemo = model.demo
        detailGeneration = generation; detailLoading = true; detail = nil; detailFailure = nil
        defer { if detailGeneration == generation { detailLoading = false } }
        do {
            let result = isDemo ? QueueDemo.detail(summary, joined: demoJoined, taken: model.demoMine.count) : try await client.queueDetails(summary)
            guard generation == detailGeneration, selectedID == id, scope == model.shopScopeKey, !Task.isCancelled else { return }
            detail = result
        } catch is CancellationError { }
        catch {
            guard generation == detailGeneration, selectedID == id, scope == model.shopScopeKey else { return }
            detailFailure = error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }

    private func confirmAction() {
        guard let queue = actionQueue, queue.id == selectedID, actionScope == model.shopScopeKey else { return }
        let join = !queue.people.contains(where: \.isMe), code = qr, client = model.api, isDemo = model.demo
        model.perform {
            if isDemo {
                guard model.active || !join else { throw CourierError(message: "Сначала начни демонстрационную смену.") }
                if join { demoJoined.insert(queue.id) } else { demoJoined.remove(queue.id) }
                model.demoQueueJoined = !demoJoined.isEmpty
            } else { try await client.changeQueue(queue.id, join: join, qr: code) }
        }
    }
}
