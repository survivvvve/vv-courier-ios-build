import SwiftUI

@MainActor final class InspectionDemoState: ObservableObject {
    static let shared = InspectionDemoState()
    @Published var checked = Set<String>()
    func snapshot(parcels: [Parcel], after: Bool) -> InspectionSnapshot {
        let rows: [[String: Any]] = parcels.flatMap { parcel in
            (1...2).map { index in
                let id = "DEMO-\(parcel.id)-\(index)"
                return ["id_package": id, "id_parcel": parcel.id, "cells": "ДЕМО-1", "cancelled": "0", "check": checked.contains("before:" + id) ? "1" : "0", "check_after": checked.contains("after:" + id) ? "1" : "0"]
            }
        }
        return InspectionSnapshot(parcels: parcels, rows: rows, mode: 1, after: after)
    }
}

/// Common batch departure gate. It never starts a lone order behind the batch.
struct BatchDepartureControl: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var demoState = InspectionDemoState.shared
    var refresh: () async -> Void
    @State private var snapshot: InspectionSnapshot?
    @State private var failure: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var presented = false
    @State private var confirming = false
    @State private var loadedOwner = ""
    private var picked: [Parcel] { snapshot?.parcels.filter { $0.status == "pickuped" } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !loaded && snapshot == nil { ProgressView("Проверяю готовность к выезду…").font(.caption) }
            if let failure { CourierErrorCard(message: failure) { Task { await load() } } }
            if let snapshot, !picked.isEmpty {
                CourierCard {
                    HStack {
                        Text("Перед выездом").font(.subheadline.weight(.semibold))
                        Spacer(); Text("Заказов: \(snapshot.parcels.count)").font(.caption).foregroundStyle(Palette.muted)
                    }
                    if snapshot.mode != 0 {
                        Text("Подтверждено пакетов: \(snapshot.packages.filter { !$0.cancelled && $0.checked }.count) из \(snapshot.packages.filter { !$0.cancelled }.count)").font(.caption).foregroundStyle(Palette.muted)
                    }
                    ForEach(picked.filter { truth($0.raw["has_partner_order"]) }) { parcel in PartnerPickupLink(parcel: parcel, refresh: refresh) }
                    Button {
                        if snapshot.allChecked { confirming = true } else { presented = true }
                    } label: {
                        Label(snapshot.allChecked ? "Начать доставку" : snapshot.mode == 2 ? "Проверить пакеты" : "Сканировать", systemImage: snapshot.allChecked ? "arrow.up.right" : "qrcode.viewfinder")
                    }.buttonStyle(CourierButtonStyle(primary: true)).disabled(model.busy || loading || model.sessionExpired).accessibilityIdentifier(snapshot.allChecked ? "departure.start" : "departure.scan")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("departure.batch")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task(id: model.identity + ":" + String(model.revision)) {
            if loadedOwner != model.identity {
                loadedOwner = model.identity; loading = false; loaded = false; snapshot = nil; failure = nil; presented = false; confirming = false
            }
            await load()
        }
        .onChange(of: demoState.checked) { _, _ in if model.demo { snapshot = demoState.snapshot(parcels: model.demoMine, after: false) } }
        .sheet(isPresented: $presented) {
            NavigationStack {
                InspectionBatchView(after: false, parcelID: nil) {
                    let owner = model.identity
                    presented = false; Task { await load(); guard model.identity == owner, !Task.isCancelled else { return }; await refresh() }
                }.toolbar { Button("Закрыть") { presented = false }.disabled(model.busy) }.modifier(CourierErrors())
            }
        }
        .confirmationDialog("Начать доставку всей партии: \(picked.count) заказов?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Начать доставку") { start() }
        } message: { Text("Проверь, что все пакеты с тобой, а для наличных и терминала есть сдача и рабочий терминал.") }
    }
    @MainActor private func load() async {
        guard !loading, !model.busy else { return }
        let owner = model.identity, client = model.api
        loading = true; failure = nil
        defer { if model.identity == owner { loading = false; loaded = true } }
        if model.demo { snapshot = demoState.snapshot(parcels: model.demoMine, after: false); return }
        do {
            let current = try await client.feed(.mine)
            guard !Task.isCancelled, model.identity == owner else { return }
            if !current.parcels.contains(where: { $0.status == "pickuped" }) { snapshot = nil; return }
            let mode = try InspectionSnapshot.mode(checking: current.checking, parcels: current.parcels, after: false)
            let rows = mode == 0 ? [] : try await client.packageRows(parcelIDs: current.parcels.map(\.id))
            guard !Task.isCancelled, model.identity == owner else { return }
            snapshot = InspectionSnapshot(parcels: current.parcels, rows: rows, mode: mode, after: false)
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, model.identity == owner else { return }
            snapshot = nil; failure = error.localizedDescription
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }
    private func start() {
        guard let snapshot, snapshot.allChecked else { return }
        let ids = snapshot.parcelIDs, client = model.api, owner = model.identity, demo = model.demo
        model.perform {
            guard model.identity == owner, !Task.isCancelled else { return }
            if demo {
                guard Set(ids) == Set(model.demoMine.map(\.id)) else { throw CourierError(message: "Демо: состав партии изменился. Обнови список.") }
                for index in model.demoMine.indices where model.demoMine[index].status == "pickuped" { model.demoMine[index].status = "on_the_way" }
            } else { try await client.startDeliveryBatch(expectedParcelIDs: ids) }
            guard model.identity == owner, !Task.isCancelled else { return }
            await refresh()
        }
    }
}

struct InspectionBatchView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var demoState = InspectionDemoState.shared
    let after: Bool
    let parcelID: String?
    let onFinished: () -> Void
    @State private var snapshot: InspectionSnapshot?
    @State private var loading = false
    @State private var working = false
    @State private var operationTask: Task<Void, Never>?
    @State private var ownership = InspectionRequestOwnership()
    @State private var failure: String?
    @State private var status: String?
    @State private var scanning = false
    @State private var skipAfterCameraDismissal = false
    @State private var scanBlocked = false
    @State private var acceptedScans = Set<String>()
    @State private var scannerRestartToken = 0
    @State private var skipPresented = false
    @State private var visualSelection = Set<String>()
    private var canFinish: Bool {
        guard let snapshot, !loading, !working else { return false }
        if snapshot.mode == 2 && after { return snapshot.packages.contains { !$0.cancelled } && snapshot.packages.filter { !$0.cancelled }.allSatisfy { visualSelection.contains($0.packageID) } }
        return snapshot.allChecked
    }
    var body: some View {
        CourierPage("Проверка пакетов", subtitle: after ? "У покупателя" : "Все взятые заказы · перед выездом", artwork: 2) {
            if model.demo { DemoBanner() }
            if loading { ProgressView("Загружаю всю партию…").frame(maxWidth: .infinity) }
            if let failure { CourierErrorCard(message: failure) { Task { await load() } } }
            if let status { Text(status).font(.subheadline).foregroundStyle(Palette.accent).accessibilityIdentifier("inspection.status") }
            if let snapshot {
                CourierCard {
                    Text(snapshot.mode == 2 ? "Визуальная проверка" : snapshot.mode == 0 ? "ВВ не требует проверки" : "Сканирование стикеров").font(.headline)
                    Text("Заказов: \(snapshot.parcels.count) · Подтверждено: \(snapshot.packages.filter { !$0.cancelled && $0.checked }.count)/\(snapshot.packages.filter { !$0.cancelled }.count)").font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("inspection.progress")
                    Text(after ? "Подтверждай только пакеты, которые передаёшь этому покупателю." : "Сканируй пакеты подряд в любом порядке. Камера остаётся открытой; каждый результат подтверждает ВВ.").font(.caption).foregroundStyle(Palette.muted)
                }
                if snapshot.mode != 0 && snapshot.packages.isEmpty {
                    CourierEmpty(title: "ВВ не передал пакеты", message: "Это не подтверждает проверку. Обнови список или обратись к куратору.", symbol: "shippingbox")
                }
                ForEach(snapshot.parcels) { parcel in
                    let packages = snapshot.packages.filter { $0.parcelID == parcel.id }
                    if !packages.isEmpty {
                        CourierCard("Заказ " + parcel.label) {
                            ForEach(packages) { package in packageRow(package, mode: snapshot.mode) }
                        }
                    }
                }
                if snapshot.mode == 1 && !snapshot.pending.isEmpty {
                    Button { scanBlocked = false; scanning = true } label: { Label("Сканировать", systemImage: "qrcode.viewfinder") }.buttonStyle(CourierButtonStyle(primary: true)).disabled(working || model.busy).accessibilityIdentifier("inspection.scan")
                    Button("Не читается QR / пропустить") { skipPresented = true }.buttonStyle(CourierButtonStyle()).disabled(working || model.busy).accessibilityIdentifier("inspection.skip")
                }
                Button(after ? "Проверка завершена" : "Готово · к выезду") { finish() }.buttonStyle(CourierButtonStyle(primary: snapshot.allChecked)).disabled(!canFinish || model.busy).accessibilityIdentifier("inspection.finish")
            }
            Button("Обновить пакеты") { Task { await load() } }.buttonStyle(CourierButtonStyle()).disabled(loading || working || model.busy)
        }
        .accessibilityIdentifier("inspection.screen")
        .task(id: model.identity) {
            ownership.invalidate(); operationTask?.cancel()
            snapshot = nil; loading = false; working = false; status = nil; failure = nil
            acceptedScans = []; visualSelection = []; scanning = false; skipPresented = false
            await load()
        }
        .interactiveDismissDisabled(working)
        .onDisappear { operationTask?.cancel() }
        .onChange(of: model.identity) { _, _ in operationTask?.cancel() }
        .sheet(isPresented: $scanning, onDismiss: {
            guard skipAfterCameraDismissal else { return }
            skipAfterCameraDismissal = false
            if snapshot?.pending.isEmpty == false { skipPresented = true }
        }) {
            let scannerOwner = model.identity
            NavigationStack {
                VStack(spacing: 12) {
                    if model.demo {
                        Text("Демо без камеры").font(.headline)
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(snapshot?.pending ?? []) { package in
                                    Button("Сканировать " + package.packageID) { scan(package.packageID) }.buttonStyle(CourierButtonStyle()).disabled(working || scanBlocked).accessibilityIdentifier("inspection.demo-scan." + package.packageID)
                                }
                            }
                        }.frame(maxHeight: .infinity).accessibilityIdentifier("inspection.camera.demo-packages")
                    } else {
                        QRScanner(onCode: { code in guard model.identity == scannerOwner else { return }; scan(code) }, onError: { guard model.identity == scannerOwner else { return }; failure = $0; scanBlocked = true }, continuous: true, paused: working || scanBlocked || snapshot?.allChecked == true, restartToken: scannerRestartToken)
                            .clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
                    }
                    Button("Не читается QR / пропустить") {
                        skipAfterCameraDismissal = true
                        scanning = false
                    }.buttonStyle(CourierButtonStyle()).disabled(working || loading || model.busy || snapshot?.pending.isEmpty != false).accessibilityIdentifier("inspection.camera.skip")
                    Text(working ? "Проверяем в ВВ…" : snapshot?.allChecked == true ? "Все пакеты подтверждены" : "Наведи камеру на QR стикера").font(.headline)
                    if let status { Text(status).font(.subheadline).foregroundStyle(Palette.accent) }
                    if let failure {
                        Text(failure).font(.subheadline).foregroundStyle(Palette.warning)
                        Button("Обновить состояние и продолжить") { Task { await load() } }.buttonStyle(CourierButtonStyle()).disabled(working || loading)
                    }
                    if snapshot?.allChecked == true { Button("Готово") { scanning = false }.buttonStyle(CourierButtonStyle(primary: true)) }
                }.padding(14).background(Palette.background).navigationTitle("Сканер пакетов").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Закрыть") { scanning = false }.disabled(working) }.interactiveDismissDisabled(working)
            }
        }
        .sheet(isPresented: $skipPresented) {
            if let snapshot {
                let owner = model.identity
                NavigationStack {
                    InspectionSkipView(initial: snapshot) { updated in
                        guard model.identity == owner else { return }
                        self.snapshot = updated; failure = nil; status = "Состояние пакетов обновлено."
                    }
                        .toolbar { Button("Закрыть") { skipPresented = false }.disabled(model.busy) }
                }
            }
        }
    }
    private func packageRow(_ package: InspectionPackage, mode: Int) -> some View {
        let visual = mode == 2 && after ? visualSelection.contains(package.packageID) : package.checked
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: package.cancelled ? "xmark.circle" : visual ? "checkmark.circle.fill" : "shippingbox").foregroundStyle(package.cancelled ? Palette.muted : visual ? Palette.success : Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.packageID).font(.subheadline.weight(.medium)).textSelection(.enabled)
                Text(package.cell.isEmpty ? "Ячейка не указана ВВ" : "Ячейка " + package.cell).font(.caption).foregroundStyle(Palette.muted)
                Text(package.cancelled ? "Отменён" : visual ? "Подтверждён" : "Ожидает проверки").font(.caption2).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            if mode == 2 && !package.cancelled {
                Button { mark(package, checked: !visual) } label: { Image(systemName: visual ? "checkmark.square.fill" : "square").frame(width: 36, height: 36) }.buttonStyle(.plain).disabled(working || model.busy).accessibilityLabel("Пакет " + package.packageID + (visual ? ", снять отметку" : ", проверен"))
            }
        }.padding(.vertical, 4).accessibilityElement(children: .contain).accessibilityIdentifier("inspection.package." + package.id)
    }
    @MainActor private func readSnapshot(client: CourierAPI, demo: Bool) async throws -> InspectionSnapshot {
        if demo { return demoState.snapshot(parcels: after ? model.demoMine.filter { $0.id == parcelID } : model.demoMine, after: after) }
        return try await client.inspectionSnapshot(after: after, parcelID: parcelID)
    }
    private func isCurrent(_ ticket: InspectionRequestOwnership.Ticket) -> Bool {
        ownership.accepts(ticket, owner: model.identity, cancelled: Task.isCancelled)
    }
    private func checkOwner(_ ticket: InspectionRequestOwnership.Ticket) throws {
        guard isCurrent(ticket) else { throw CancellationError() }
    }
    @MainActor private func load() async {
        guard !loading, !working else { return }
        let client = model.api, demo = model.demo, ticket = ownership.begin(owner: model.identity)
        loading = true; failure = nil
        defer { if ownership.accepts(ticket, owner: model.identity, cancelled: false) { loading = false } }
        do {
            let updated = try await readSnapshot(client: client, demo: demo)
            try checkOwner(ticket)
            if Set(snapshot?.parcelIDs ?? []) != Set(updated.parcelIDs) { acceptedScans = [] }
            snapshot = updated; scanBlocked = false; scannerRestartToken += 1
            visualSelection.formIntersection(Set(updated.packages.filter { !$0.cancelled }.map(\.packageID)))
            visualSelection.formUnion(updated.packages.filter { !$0.cancelled && $0.checked }.map(\.packageID))
        } catch is CancellationError {} catch {
            guard isCurrent(ticket) else { return }
            failure = error.localizedDescription; scanBlocked = true
            if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
        }
    }
    private func operation(_ action: @escaping @MainActor (CourierAPI, Bool, InspectionRequestOwnership.Ticket) async throws -> Void) {
        guard !working, !loading, !model.busy else { return }
        let client = model.api, demo = model.demo, ticket = ownership.begin(owner: model.identity)
        working = true; model.busy = true; failure = nil
        operationTask = Task { @MainActor in
            defer { if ownership.accepts(ticket, owner: model.identity, cancelled: false) { working = false; model.busy = false } }
            do { try checkOwner(ticket); try await action(client, demo, ticket) }
            catch is CancellationError { if isCurrent(ticket) { scanBlocked = true } }
            catch {
                guard isCurrent(ticket) else { return }
                // Read back after uncertain failures, but never repeat a write.
                let updated = try? await readSnapshot(client: client, demo: demo)
                guard isCurrent(ticket) else { return }
                if let updated { snapshot = updated }
                failure = error.localizedDescription; scanBlocked = true
                if (error as? CourierError)?.statusCode == 401 { model.sessionExpired = true }
            }
        }
    }
    private func scan(_ code: String) {
        guard let snapshot, !scanBlocked, snapshot.mode == 1 else { return }
        if acceptedScans.contains(code) || snapshot.packages.contains(where: { $0.packageID == code && $0.checked }) { return }
        operation { client, demo, ticket in
            if demo {
                guard snapshot.pending.contains(where: { $0.packageID == code }) else { throw CourierError(message: "Демо: код не относится к этой партии.") }
                demoState.checked.insert((after ? "after:" : "before:") + code)
            } else {
                _ = try await client.scanInspectionPackage(expectedIDs: snapshot.parcelIDs, code: code, after: after, parcelID: parcelID)
                try checkOwner(ticket)
            }
            let updated = try await readSnapshot(client: client, demo: demo)
            try checkOwner(ticket)
            // Only a confirmed package or NO_CHECK can suppress another scan.
            guard updated.confirmsScan(code) else {
                throw CourierError(message: "ВВ ещё не подтвердил этот пакет. Обнови состояние перед повтором.")
            }
            acceptedScans.insert(code); self.snapshot = updated
            status = updated.allChecked ? "ВВ подтвердил все пакеты." : "Пакет подтверждён. Сканируй следующий."
            if demo { status = "Демо: отметка только на экране." }
        }
    }
    private func mark(_ package: InspectionPackage, checked: Bool) {
        if after { if checked { visualSelection.insert(package.packageID) } else { visualSelection.remove(package.packageID) }; return }
        operation { client, demo, ticket in
            try await client.markPackagesChecked(parcelID: package.parcelID, ids: [package.packageID], checked: checked)
            try checkOwner(ticket)
            let updated = try await readSnapshot(client: client, demo: demo)
            try checkOwner(ticket); snapshot = updated
        }
    }
    private func finish() {
        guard canFinish, let snapshot else { return }
        operation { client, demo, ticket in
            if !demo {
                if after {
                    if snapshot.mode == 2 { try await client.finishPackageInspection(parcelID: parcelID ?? "", after: true, confirmedIDs: Array(visualSelection)) }
                    else { try await client.verifyPackageInspection(parcelID: parcelID ?? "", after: true) }
                } else { try await client.verifyBatchInspection(expectedIDs: snapshot.parcelIDs) }
                try checkOwner(ticket)
            }
            onFinished()
        }
    }
}
