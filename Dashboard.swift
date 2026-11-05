import SwiftUI

/// The working shift stays within reach on the orders screen; it is not another dashboard tab.
struct ShiftControlBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmation = false
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(model.active ? Palette.success : Palette.muted).frame(width: 7, height: 7)
            Text(model.shiftKnown ? model.active ? "На смене" : "Не на смене" : "Проверяем смену…")
                .font(.subheadline.weight(.medium)).accessibilityIdentifier("shift.status")
            Spacer(minLength: 8)
            if model.busy { ProgressView().controlSize(.small) }
            Button(model.active ? "Завершить" : "Начать смену") { confirmation = true }
                .font(.subheadline.weight(.semibold)).buttonStyle(.borderedProminent).controlSize(.small)
                .frame(minHeight: 44).disabled(!model.shiftKnown || model.busy || model.sessionExpired)
                .accessibilityIdentifier("shift.toggle")
        }.padding(.horizontal, 12).padding(.vertical, 3).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .confirmationDialog(model.active ? "Завершить текущую смену?" : "Начать смену?", isPresented: $confirmation, titleVisibility: .visible) {
                Button("Подтвердить") {
                    let target = !model.active, client = model.api, owner = model.identity
                    model.perform {
                        guard model.identity == owner, !Task.isCancelled else { throw CancellationError() }
                        if model.demo {
                            if !target && !model.demoMine.isEmpty { throw CourierError(message: "Сначала заверши демонстрационные заказы в разделе «Мои».") }
                            model.active = target
                        } else {
                            do { try await client.changeShift(active: target) }
                            catch is CancellationError { throw CancellationError() }
                            catch {
                                let actionFailure = error
                                guard model.identity == owner, !Task.isCancelled else { throw CancellationError() }
                                model.shiftKnown = false
                                if (actionFailure as? CourierError)?.statusCode != 401 {
                                    do {
                                        let actual = try await client.activeShift()
                                        guard model.identity == owner, !Task.isCancelled else { throw CancellationError() }
                                        model.active = actual; model.shiftKnown = true
                                    } catch is CancellationError { throw CancellationError() }
                                    catch {
                                        guard model.identity == owner, !Task.isCancelled else { throw CancellationError() }
                                        if (error as? CourierError)?.statusCode == 401 { throw error }
                                    }
                                }
                                throw actionFailure
                            }
                            guard model.identity == owner, !Task.isCancelled else { throw CancellationError() }
                            let active = try await client.activeShift()
                            guard model.identity == owner, !Task.isCancelled else { throw CancellationError() }
                            model.active = active
                        }
                        model.shiftKnown = true
                        if model.active { model.selectedFeed = .mine }
                    }
                }
            } message: { Text(model.active ? "Все взятые заказы должны быть доставлены или возвращены." : "ВВ проверит запланированный выход и допуски к работе.") }
    }
}

struct DashboardView: View {
    var body: some View {
        CourierPage("Смена") {
            ShiftControlBar()
            CourierCard {
                NavigationLink { ScheduleView() } label: { CourierMenuRow(title: "График и запись на выход", symbol: "calendar") }.accessibilityIdentifier("dashboard.schedule")
                Divider()
                NavigationLink { TerminalView() } label: { CourierMenuRow(title: "Терминал", symbol: "creditcard") }.accessibilityIdentifier("dashboard.terminal")
            }
        }
    }
}

struct ReauthenticationCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        CourierCard {
            Label("Сессия ВВ завершена", systemImage: "person.crop.circle.badge.exclamationmark").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.warning)
            Text("Войди заново, чтобы обновлять данные и работать с заказами.").font(.subheadline).foregroundStyle(Palette.muted)
            Button("Войти заново") { model.loginPresented = true }.buttonStyle(CourierButtonStyle(primary: true))
        }
    }
}
