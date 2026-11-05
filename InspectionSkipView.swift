import SwiftUI

/// Selection is by package identity, never by cell. Shared cells remain separate
/// rows and separate VV requests; partial success is read back before continuing.
struct InspectionSkipView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var demoState = InspectionDemoState.shared
    let initial: InspectionSnapshot
    let onUpdated: (InspectionSnapshot) -> Void
    @State private var snapshot: InspectionSnapshot?
    @State private var selected = Set<String>()
    @State private var policies: [Int: InspectionSkipPolicy] = [:]
    @State private var reasons: [InspectionSkipReason] = []
    @State private var reasonID = ""
    @State private var customReason = ""
    @State private var failure: String?
    @State private var status: String?
    @State private var loading = false
    @State private var working = false
    @State private var operationTask: Task<Void, Never>?
    @State private var ownership = InspectionRequestOwnership()
    @State private var loadedOwner: String?
    @State private var scanningTT = false
    @State private var confirmingReason = false
    private var current: InspectionSnapshot {
        if let loadedOwner, loadedOwner != model.identity { return InspectionSnapshot(parcels: [], rows: [], mode: 0, after: initial.after) }
        return snapshot ?? initial
    }
    private var picked: [InspectionPackage] { current.pending.filter { selected.contains($0.id) } }
    private var reasonAllowed: Bool {
        !picked.isEmpty && picked.allSatisfy { package in
            guard let shop = current.parcels.first(where: { $0.id == package.parcelID })?.shopID, let policy = policies[shop] else { return false }
            return current.after ? policy.after : policy.before
        }
    }
    private var reasonReady: Bool { reasonID == "-1" ? !customReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : reasons.contains { $0.id == reasonID } }
    var body: some View {
        CourierPage("Не читается QR", subtitle: "Выбери каждый проблемный пакет отдельно", artwork: 2) {
            if model.demo { DemoBanner() }
            Text("Сначала отсканируй все читаемые стикеры. Ячейка — только подсказка: пакеты с одинаковой ячейкой отмечаются отдельно.").font(.subheadline).foregroundStyle(Palette.muted)
            if loading { ProgressView("Загружаю разрешения ВВ…") }
            if let failure { CourierErrorCard(message: failure) { Task { await load() } } }
            if let status { Text(status).font(.subheadline).foregroundStyle(Palette.accent) }
            ForEach(current.parcels) { parcel in
                let packages = current.pending.filter { $0.parcelID == parcel.id }
                if !packages.isEmpty {
                    CourierCard("Заказ " + parcel.label) {
                        ForEach(packages) { package in
                            Button {
                                if !selected.insert(package.id).inserted { selected.remove(package.id) }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: selected.contains(package.id) ? "checkmark.square.fill" : "square").foregroundStyle(selected.contains(package.id) ? Palette.accent : Palette.muted).font(.title3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(package.packageID).font(.subheadline.weight(.medium)).foregroundStyle(Palette.text)
                                        Text(package.cell.isEmpty ? "Ячейка не указана ВВ" : "Ячейка " + package.cell).font(.caption).foregroundStyle(Palette.muted)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(working || loading).accessibilityIdentifier("inspection.skip.package." + package.id).accessibilityValue(selected.contains(package.id) ? "Выбран" : "Не выбран")
                        }
                    }
                }
            }
            if current.pending.isEmpty { CourierEmpty(title: "Нет непроверенных пакетов", message: "ВВ уже подтвердил доступные пакеты.", symbol: "checkmark.circle") }
            if !picked.isEmpty {
                CourierCard {
                    Text("Выбрано пакетов: \(picked.count)").font(.subheadline.weight(.semibold))
                    if !current.after {
                        Text("Попроси у куратора QR-код ТТ. Каждый выбранный пакет будет отдельно отправлен в ВВ для подтверждения.").font(.caption).foregroundStyle(Palette.muted)
                        Button { scanningTT = true } label: { Label("Сканировать QR-код ТТ", systemImage: "qrcode.viewfinder") }.buttonStyle(CourierButtonStyle(primary: true)).disabled(working || loading).accessibilityIdentifier("inspection.skip.tt")
                    }
                    if reasonAllowed {
                        Picker("Причина", selection: $reasonID) {
                            Text("Выбери причину").tag("")
                            ForEach(reasons) { reason in Text(reason.text).tag(reason.id) }
                            Text("Другая причина").tag("-1")
                        }.pickerStyle(.menu).accessibilityIdentifier("inspection.skip.reason")
                        if reasonID == "-1" { TextField("Укажи причину", text: $customReason, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("inspection.skip.custom") }
                        Button("Пропустить выбранные · \(picked.count)") { confirmingReason = true }.buttonStyle(CourierButtonStyle()).disabled(!reasonReady || working || loading).accessibilityIdentifier("inspection.skip.submit")
                    } else {
                        Text(current.after ? "ВВ не разрешает пропуск для выбранных пакетов. Обратись к куратору." : "Без QR-кода ТТ пропуск для выбранных пакетов не разрешён ВВ.").font(.caption).foregroundStyle(Palette.warning)
                    }
                }
            }
            Button("Готово") { dismiss() }.buttonStyle(CourierButtonStyle()).disabled(working).accessibilityIdentifier("inspection.skip.done")
        }.accessibilityIdentifier("inspection.skip.screen").task(id: model.identity) {
            if let loadedOwner, loadedOwner != model.identity { ownership.invalidate(); operationTask?.cancel(); dismiss(); return }
            loadedOwner = model.identity
            await load()
        }.interactiveDismissDisabled(working)
            .onDisappear { operationTask?.cancel() }
            .onChange(of: model.identity) { _, _ in ownership.invalidate(); operationTask?.cancel(); scanningTT = false; confirmingReason = false; dismiss() }
            .confirmationDialog("Указать причину пропуска для \(picked.count) пакетов?", isPresented: $confirmingReason, titleVisibility: .visible) {
                Button("Отправить в ВВ") { submit(ttCode: nil) }
            }
            .sheet(isPresented: $scanningTT) {
                let scannerOwner = model.identity
                NavigationStack {
                    Group {
                        if model.demo { Button("Демо QR ТТ") { scanningTT = false; submit(ttCode: "DEMO-TT") }.buttonStyle(CourierButtonStyle(primary: true)) }
                        else { QRScanner(onCode: { code in guard model.identity == scannerOwner else { return }; scanningTT = false; submit(ttCode: code) }, onError: { guard model.identity == scannerOwner else { return }; failure = $0; scanningTT = false }) }
                    }.navigationTitle("QR-код ТТ от куратора").navigationBarTitleDisplayMode(.inline).toolbar { Button("Отмена") { scanningTT = false } }
                }
            }
    }
    private func isCurrent(_ ticket: InspectionRequestOwnership.Ticket) -> Bool {
        ownership.accepts(ticket, owner: model.identity, cancelled: Task.isCancelled)
    }
    private func checkOwner(_ ticket: InspectionRequestOwnership.Ticket) throws {
        guard isCurrent(ticket) else { throw CancellationError() }
    }
    @MainActor private func freshSnapshot(client: CourierAPI, demo: Bool, basis: InspectionSnapshot) async throws -> InspectionSnapshot {
        if demo { return demoState.snapshot(parcels: basis.parcels, after: basis.after) }
        return try await client.inspectionSnapshot(after: basis.after, parcelID: basis.after ? basis.parcelIDs.first : nil)
    }
    @MainActor private func load() async {
        guard !working, !loading else { return }
        let client = model.api, demo = model.demo, basis = current, ticket = ownership.begin(owner: model.identity)
        loading = true; failure = nil
        defer { if ownership.accepts(ticket, owner: model.identity, cancelled: false) { loading = false } }
        do {
            let updated = try await freshSnapshot(client: client, demo: demo, basis: basis)
            try checkOwner(ticket)
            let fetchedPolicies: [Int: InspectionSkipPolicy], fetchedReasons: [InspectionSkipReason]
            if demo {
                fetchedPolicies = updated.parcels.compactMap(\.shopID).reduce(into: [Int: InspectionSkipPolicy]()) { $0[$1] = InspectionSkipPolicy(before: true, after: true) }
                fetchedReasons = [InspectionSkipReason(id: "demo-damaged", text: "Демо: стикер повреждён")]
            } else {
                fetchedPolicies = try await client.inspectionSkipPolicies()
                try checkOwner(ticket)
                fetchedReasons = try await client.inspectionSkipReasons()
                try checkOwner(ticket)
            }
            policies = fetchedPolicies; reasons = fetchedReasons
            snapshot = updated; selected.formIntersection(Set(updated.pending.map(\.id))); onUpdated(updated)
        } catch is CancellationError {} catch {
            guard isCurrent(ticket) else { return }
            failure = error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }
    private func submit(ttCode: String?) {
        guard !working, !loading, !model.busy, !picked.isEmpty else { return }
        guard ttCode != nil || (reasonAllowed && reasonReady) else { return }
        let packages = picked, expected = current.parcelIDs, after = current.after, basis = current
        let selectedReason = reasonID, text = customReason, client = model.api, demo = model.demo
        let ticket = ownership.begin(owner: model.identity)
        working = true; model.busy = true; failure = nil; status = nil
        operationTask = Task { @MainActor in
            defer { if ownership.accepts(ticket, owner: model.identity, cancelled: false) { working = false; model.busy = false } }
            do {
                for package in packages {
                    try checkOwner(ticket)
                    if demo { demoState.checked.insert((after ? "after:" : "before:") + package.packageID) }
                    else {
                        _ = try await client.scanInspectionPackage(expectedIDs: expected, code: ttCode ?? package.packageID, after: after, parcelID: after ? expected.first : nil, ttPackageID: ttCode == nil ? nil : package.packageID, reasonID: ttCode == nil ? selectedReason : nil, customReason: text)
                        try checkOwner(ticket)
                    }
                    let updated = try await freshSnapshot(client: client, demo: demo, basis: basis)
                    try checkOwner(ticket)
                    guard updated.confirmsScan(package.packageID) else { throw CourierError(message: "ВВ ещё не подтвердил пакет. Обнови состояние перед повтором.") }
                    snapshot = updated; onUpdated(updated)
                    selected.formIntersection(Set(updated.pending.map(\.id)))
                }
                status = demo ? "Демо: выбранные пакеты отмечены только на экране." : "ВВ подтвердил выбранные пакеты."
            } catch is CancellationError {} catch {
                guard isCurrent(ticket) else { return }
                let updated = try? await freshSnapshot(client: client, demo: demo, basis: basis)
                guard isCurrent(ticket) else { return }
                if let updated { snapshot = updated; onUpdated(updated); selected.formIntersection(Set(updated.pending.map(\.id))) }
                failure = "Часть отметок могла быть принята. Не повторяй отправку без проверки состояния. " + error.localizedDescription
                if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
            }
        }
    }
}
